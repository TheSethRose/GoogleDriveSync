//
//  RcloneWrapper.swift
//  DriveSync
//
//  Created by saihgupr on 2024-12-11.
//  Edited by MichasCoup on 2026-07-26.
//

import Foundation

enum BisyncMode {
    case normal
    case initial
    case resync
}

enum RcloneError: LocalizedError {
    case notInstalled
    case configurationFailed(String)
    case syncFailed(String)
    case bisyncNeedsResync(String)
    case invalidRemote(String)
    case unsafeLocalFolder(String)
    /// Bisync stopped before deleting more files than the safety limit allows.
    case deletesNeedApproval(PendingDeletes)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "rclone is not installed. Please install it via Homebrew: brew install rclone"
        case .configurationFailed(let message):
            return "Configuration failed: \(message)"
        case .syncFailed(let message):
            return "Sync failed: \(message)"
        case .bisyncNeedsResync(let message):
            return "Bi-Sync failed and requires a resync: \(message)"
        case .invalidRemote(let name):
            return "Invalid remote: \(name)"
        case .unsafeLocalFolder(let message):
            return "Skipped to protect your files: \(message)"
        case .deletesNeedApproval(let pending):
            return "Waiting for you: \(pending.summary)"
        }
    }
}

struct RcloneRemote: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    
    var displayName: String {
        "\(name) (\(type))"
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(type)
    }
    
    static func == (lhs: RcloneRemote, rhs: RcloneRemote) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type
    }
}

actor RcloneWrapper {
    private let rclonePath: String
    private let runner = ProcessRunner.shared

    /// Folder on the remote that receives files a sync deletes or overwrites.
    static let backupFolderName = "_DriveSync Backups"
    /// Bisync asks before a run deletes more than this percentage of a folder on either side.
    static let maxDeletePercent = 50
    /// Deletes up to this count are allowed even when they exceed the percentage.
    static let alwaysAllowedDeletes = 10

    init(rclonePath: String = AppSettings.defaultRclonePath) {
        self.rclonePath = rclonePath
    }
    
    /// Cancel any currently running sync operation
    func cancelCurrentOperation() async {
        await runner.terminateCurrentProcess()
    }
    
    // MARK: - Installation Check
    
    func isInstalled() async -> Bool {
        do {
            let result = try await runner.run(rclonePath, arguments: ["version"])
            return result.isSuccess
        } catch {
            return false
        }
    }
    
    func version() async throws -> String {
        let result = try await runner.run(rclonePath, arguments: ["version"])
        guard result.isSuccess else {
            throw RcloneError.notInstalled
        }
        // Extract first line (e.g., "rclone v1.65.0")
        return result.stdout.components(separatedBy: "\n").first ?? result.stdout
    }
    
    // MARK: - Remote Management
    
    func listRemotes() async throws -> [RcloneRemote] {
        let result = try await runner.run(rclonePath, arguments: ["listremotes", "--long"])
        guard result.isSuccess else {
            throw RcloneError.configurationFailed(result.stderr)
        }
        
        var remotes: [RcloneRemote] = []
        let lines = result.stdout.components(separatedBy: "\n")
        
        for line in lines where !line.isEmpty {
            // Format: "remotename: type"
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 {
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let type = parts[1].trimmingCharacters(in: .whitespaces)
                remotes.append(RcloneRemote(name: name, type: type))
            }
        }
        
        return remotes
    }
    
    /// Creates a new Google Drive remote using in-app browser OAuth flow
    func createDriveAccount(name: String) async throws {
        let args = [
            "config", "create", name, "drive",
            "scope", "drive",
            "config_is_local", "true",
            "--non-interactive"
        ]
        
        // This will block and wait for the user to complete OAuth in their browser
        let result = try await runner.run(rclonePath, arguments: args)
        guard result.isSuccess else {
            throw RcloneError.configurationFailed("Failed to authenticate: \(result.stderr)")
        }
    }
    
    /// Rename an existing remote
    func renameRemote(from oldName: String, to newName: String) async throws {
        // rclone has no rename command. Renaming the section header in the config file keeps
        // every option and never passes the OAuth token on a command line.
        let fileResult = try await runner.run(rclonePath, arguments: ["config", "file"])
        guard fileResult.isSuccess,
              let configPath = fileResult.stdout
                .components(separatedBy: "\n")
                .last(where: { $0.hasPrefix("/") })?
                .trimmingCharacters(in: .whitespaces) else {
            throw RcloneError.configurationFailed("Could not find the rclone config file")
        }

        let contents = try String(contentsOfFile: configPath, encoding: .utf8)
        if contents.hasPrefix("# Encrypted rclone configuration") {
            throw RcloneError.configurationFailed("Encrypted rclone configs can't be renamed here. Use 'rclone config' instead.")
        }

        var lines = contents.components(separatedBy: "\n")
        guard !lines.contains("[\(newName)]") else {
            throw RcloneError.configurationFailed("An account named \(newName) already exists")
        }
        guard let index = lines.firstIndex(of: "[\(oldName)]") else {
            throw RcloneError.invalidRemote(oldName)
        }

        lines[index] = "[\(newName)]"
        // An atomic write replaces the file, so restore its owner-only permissions afterwards.
        let permissions = (try? FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions]) ?? 0o600
        try lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: configPath)
    }
    
    /// Delete a remote
    func deleteRemote(name: String) async throws {
        let result = try await runner.run(rclonePath, arguments: ["config", "delete", name])
        guard result.isSuccess else {
            throw RcloneError.configurationFailed("Failed to delete remote: \(result.stderr)")
        }
    }
    
    /// Get the Google Drive folder ID for a remote path
    /// Returns "root" for empty paths (My Drive root), or the actual folder ID
    func getFolderID(remote: String, path: String) async -> String? {
        do {
            // If path is empty, we're looking at the root (My Drive)
            if path.isEmpty {
                // Return special marker for root
                return "root"
            }
            
            // To get the folder ID, we need to list the parent directory and find our folder by name
            // Split path to get parent and folder name
            let pathComponents = path.components(separatedBy: "/")
            let folderName = pathComponents.last ?? path
            let parentPath = pathComponents.dropLast().joined(separator: "/")
            
            // List the parent directory (or root if no parent)
            let listPath = parentPath.isEmpty ? "\(remote):" : "\(remote):\(parentPath)"
            let result = try await runner.run(rclonePath, arguments: ["lsjson", listPath, "--dirs-only"])
            
            if result.isSuccess, let data = result.stdout.data(using: .utf8) {
                // Parse JSON array
                if let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    // Find our folder by name
                    for item in items {
                        if let name = item["Name"] as? String, name == folderName,
                           let id = item["ID"] as? String {
                            return id
                        }
                    }
                }
            }
        } catch {
            print("Failed to get folder ID: \(error)")
        }
        
        return nil
    }
    
    // MARK: - Sync Operations
    
    func sync(
        source: String,
        destination: String,
        ignoredPatterns: [String] = [],
        backupName: String,
        dryRun: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SyncResult {
        // An empty or missing source would make sync delete everything on the remote.
        try Self.checkLocalFolder(source)

        var args = ["sync", source, destination, "--progress"]
        args += Self.safetyArguments()
        args += ["--backup-dir", Self.remoteBackupPath(remote: destination, backupName: backupName, stamp: Self.backupStamp())]

        for pattern in ignoredPatterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                args.append(contentsOf: ["--exclude", trimmed])
            }
        }
        
        if dryRun {
            args.append("--dry-run")
        }
        
        let startTime = Date()
        
        let result: ProcessResult
        if let progressHandler = onProgress {
            result = try await runner.runWithProgress(rclonePath, arguments: args) { output in
                progressHandler(output)
            }
        } else {
            result = try await runner.run(rclonePath, arguments: args)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        if result.isSuccess {
            return SyncResult(
                success: true,
                filesTransferred: parseFileCount(from: result.stdout),
                bytesTransferred: parseByteCount(from: result.stdout),
                duration: duration,
                error: nil
            )
        } else {
            throw RcloneError.syncFailed(Self.errorSummary(result.stdout + "\n" + result.stderr))
        }
    }

    func copy(
        source: String,
        destination: String,
        ignoredPatterns: [String] = [],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SyncResult {
        var args = ["copy", source, destination, "--progress"]
        
        for pattern in ignoredPatterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                args.append(contentsOf: ["--exclude", trimmed])
            }
        }
        
        let startTime = Date()
        
        let result: ProcessResult
        if let progressHandler = onProgress {
            result = try await runner.runWithProgress(rclonePath, arguments: args) { output in
                progressHandler(output)
            }
        } else {
            result = try await runner.run(rclonePath, arguments: args)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        if result.isSuccess {
            return SyncResult(
                success: true,
                filesTransferred: parseFileCount(from: result.stdout),
                bytesTransferred: parseByteCount(from: result.stdout),
                duration: duration,
                error: nil
            )
        } else {
            throw RcloneError.syncFailed(Self.errorSummary(result.stdout + "\n" + result.stderr))
        }
    }

    func bidirectionalSync(
        local: String,
        remote: String,
        ignoredPatterns: [String] = [],
        backupName: String,
        mode: BisyncMode,
        allowDeletes: Bool = false,
        dryRun: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SyncResult {
        // A missing folder (e.g. an unmounted volume) must never be treated as "everything was deleted".
        try Self.checkLocalFolder(local)

        let stamp = Self.backupStamp()
        var args = [
            "bisync",
            local,
            remote,
            "--progress",
            "--resilient",
            "--recover",
            "--max-lock", "2m",
            "--conflict-resolve", "newer",
            "--max-delete", String(Self.maxDeletePercent),
            "--backup-dir1", Self.localBackupPath(backupName: backupName, stamp: stamp),
            "--backup-dir2", Self.remoteBackupPath(remote: remote, backupName: backupName, stamp: stamp)
        ]
        if allowDeletes {
            args.append("--force")
        }
        args += Self.safetyArguments()

        if mode == .initial {
            // Bisync needs both folders to exist; a new destination may not be on the remote yet.
            _ = try? await runner.run(rclonePath, arguments: ["mkdir", remote])
        }

        if mode == .initial || mode == .resync {
            // A resync merges both sides without deleting anything.
            args.append(contentsOf: [
                "--resync",
                "--resync-mode", "newer"
            ])
        }

        for pattern in ignoredPatterns {
            let trimmed = pattern.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                args.append(contentsOf: [
                    "--exclude",
                    trimmed
                ])
            }
        }

        if dryRun {
            args.append("--dry-run")
        }

        let startTime = Date()

        func run(_ args: [String]) async throws -> ProcessResult {
            if let progressHandler = onProgress {
                return try await runner.runWithProgress(
                    rclonePath,
                    arguments: args
                ) { output in
                    progressHandler(output)
                }
            }
            return try await runner.run(
                rclonePath,
                arguments: args
            )
        }

        var result = try await run(args)

        // The percentage limit alone would block any delete in a small folder (1 of 1 file is 100%).
        // A few deletes are always allowed; more than that waits for the user. Either way they're backed up first.
        if !result.isSuccess, let pending = Self.blockedDeletes(result.stdout + "\n" + result.stderr) {
            guard pending.count <= Self.alwaysAllowedDeletes else {
                throw RcloneError.deletesNeedApproval(pending)
            }
            result = try await run(args + ["--force"])
        }

        let duration = Date().timeIntervalSince(startTime)

        guard result.isSuccess else {
            let errorOutput = result.stdout + "\n" + result.stderr
            let errorMessage = Self.errorSummary(errorOutput)

            // Exit code 7 is also used for critical errors that --resilient will retry on its own.
            if result.exitCode == 7 && !errorOutput.contains("retryable without --resync") {
                throw RcloneError.bisyncNeedsResync(errorMessage)
            }

            throw RcloneError.syncFailed(errorMessage)
        }

        let combinedOutput = result.stdout + "\n" + result.stderr

        return SyncResult(
            success: true,
            filesTransferred: parseFileCount(from: combinedOutput),
            bytesTransferred: parseByteCount(from: combinedOutput),
            duration: duration,
            error: nil
        )
    }

    // MARK: - Undo and Cleanup

    /// The run folders (e.g. "2026-10-26_181500") in this sync's backups, local and remote.
    private func backupStamps(remote: String, backupName: String) async -> (local: [String], remote: [String]) {
        let local = ((try? FileManager.default.contentsOfDirectory(atPath: Self.localBackupRoot(backupName: backupName))) ?? [])
            .filter { Self.backupDate(fromStamp: $0) != nil }
        let listing = try? await runner.run(rclonePath, arguments: [
            "lsf", "--dirs-only", Self.remoteBackupRoot(remote: remote, backupName: backupName)
        ])
        let remoteStamps = (listing?.isSuccess == true ? listing!.stdout : "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
            .filter { Self.backupDate(fromStamp: $0) != nil }
        return (local, remoteStamps)
    }

    /// The newest run that removed or replaced files, and how many files it saved.
    func latestBackup(remote: String, backupName: String) async -> (stamp: String, fileCount: Int)? {
        let stamps = await backupStamps(remote: remote, backupName: backupName)
        guard let stamp = (stamps.local + stamps.remote).max() else { return nil }

        var count = 0
        if stamps.local.contains(stamp),
           let files = FileManager.default.enumerator(atPath: Self.localBackupPath(backupName: backupName, stamp: stamp)) {
            count += files.allObjects.compactMap { $0 as? String }
                .filter { !$0.hasSuffix(".DS_Store") && !$0.isEmpty }
                .filter { path in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(
                        atPath: Self.localBackupPath(backupName: backupName, stamp: stamp) + "/" + path,
                        isDirectory: &isDirectory
                    )
                    return !isDirectory.boolValue
                }
                .count
        }
        if stamps.remote.contains(stamp),
           let listing = try? await runner.run(rclonePath, arguments: [
               "lsf", "-R", "--files-only", Self.remoteBackupPath(remote: remote, backupName: backupName, stamp: stamp)
           ]), listing.isSuccess {
            count += listing.stdout.split(separator: "\n").count
        }
        return (stamp, count)
    }

    /// Puts back the files a run removed. Only missing files are restored, so nothing newer is overwritten.
    /// Two-way syncs restore each side's backup to that side; one-way syncs restore into the local folder,
    /// since the next sync would otherwise remove them from the remote again.
    func restoreBackup(stamp: String, local: String, remote: String, backupName: String, twoWay: Bool) async throws {
        let stamps = await backupStamps(remote: remote, backupName: backupName)

        if stamps.local.contains(stamp) {
            let result = try await runner.run(rclonePath, arguments: [
                "copy", Self.localBackupPath(backupName: backupName, stamp: stamp), local, "--ignore-existing"
            ])
            guard result.isSuccess else {
                throw RcloneError.syncFailed(Self.errorSummary(result.stdout + "\n" + result.stderr))
            }
        }
        if stamps.remote.contains(stamp) {
            let result = try await runner.run(rclonePath, arguments: [
                "copy", Self.remoteBackupPath(remote: remote, backupName: backupName, stamp: stamp),
                twoWay ? remote : local, "--ignore-existing", "--drive-skip-gdocs"
            ])
            guard result.isSuccess else {
                throw RcloneError.syncFailed(Self.errorSummary(result.stdout + "\n" + result.stderr))
            }
        }
    }

    /// Deletes this sync's backup runs older than the cutoff. Remote ones go to the Drive trash.
    func pruneBackups(remote: String, backupName: String, olderThan cutoff: Date) async {
        let stamps = await backupStamps(remote: remote, backupName: backupName)
        let isOld = { (stamp: String) in (Self.backupDate(fromStamp: stamp) ?? .distantFuture) < cutoff }

        for stamp in stamps.local where isOld(stamp) {
            try? FileManager.default.removeItem(atPath: Self.localBackupPath(backupName: backupName, stamp: stamp))
        }
        for stamp in stamps.remote where isOld(stamp) {
            _ = try? await runner.run(rclonePath, arguments: [
                "purge", Self.remoteBackupPath(remote: remote, backupName: backupName, stamp: stamp)
            ])
        }
    }

    // MARK: - Helpers

    /// Flags shared by every sync that can delete or overwrite files.
    private static func safetyArguments() -> [String] {
        [
            // Native Google Docs/Sheets can't be downloaded as files; skipping them keeps them untouched.
            "--drive-skip-gdocs",
            // Keep the remote backup folder out of the sync itself.
            "--exclude", "/\(backupFolderName)/**"
        ]
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    private static func backupStamp() -> String {
        stampFormatter.string(from: Date())
    }

    /// The date a backup folder name like "2026-10-26_181500" stands for.
    static func backupDate(fromStamp stamp: String) -> Date? {
        stampFormatter.date(from: stamp.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// The folder holding this sync's local backups, one subfolder per run.
    private static func localBackupRoot(backupName: String) -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("GoogleDriveSync/Backups", isDirectory: true)
            .appendingPathComponent(backupName, isDirectory: true)
            .path
    }

    /// Where bisync moves local files it deletes or overwrites.
    private static func localBackupPath(backupName: String, stamp: String) -> String {
        "\(localBackupRoot(backupName: backupName))/\(stamp)"
    }

    /// The remote folder holding this sync's backups, e.g. "gdrive:_DriveSync Backups/Documents-848ED13B".
    private static func remoteBackupRoot(remote: String, backupName: String) -> String {
        let remoteName = remote.split(separator: ":", maxSplits: 1).first.map(String.init) ?? remote
        return "\(remoteName):\(backupFolderName)/\(backupName)"
    }

    /// Where remote files a sync deletes or overwrites are moved, e.g. "gdrive:_DriveSync Backups/Documents/2026-10-26_181500".
    private static func remoteBackupPath(remote: String, backupName: String, stamp: String) -> String {
        "\(remoteBackupRoot(remote: remote, backupName: backupName))/\(stamp)"
    }

    private static func checkLocalFolder(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RcloneError.unsafeLocalFolder("\(path) was not found.")
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        guard contents.contains(where: { $0 != ".DS_Store" }) else {
            throw RcloneError.unsafeLocalFolder("\(path) is empty.")
        }
    }

    /// Reads bisync's "Safety abort: too many deletes (>50%, 312 of 400) on Path1" error.
    /// Path1 is the local folder: deletes found there would be carried out on the remote.
    static func blockedDeletes(_ output: String) -> PendingDeletes? {
        guard let regex = try? NSRegularExpression(pattern: #"too many deletes \(>\d+%, (\d+) of \d+\) on (Path[12])"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let countRange = Range(match.range(at: 1), in: output),
              let pathRange = Range(match.range(at: 2), in: output),
              let count = Int(output[countRange]) else {
            return nil
        }
        return PendingDeletes(count: count, onRemote: output[pathRange] == "Path1")
    }

    /// Turns rclone's log into the lines that explain a failure, instead of only its final summary.
    static func errorSummary(_ output: String) -> String {
        let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
        let timestamp = try? NSRegularExpression(pattern: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#)

        var lines: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine
            for regex in [ansi, timestamp].compactMap({ $0 }) {
                line = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            }
            // Progress output can share a line with the error, so start at the ERROR marker.
            if let range = line.range(of: "ERROR : ") {
                line = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if !lines.contains(line) {
                    lines.append(line)
                }
            }
        }

        if lines.isEmpty {
            return output.components(separatedBy: .newlines)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? output
        }
        return lines.prefix(3).joined(separator: "\n")
    }

    private func parseFileCount(from output: String) -> Int {
        // Parse "Transferred: X / Y, 100%" pattern
        let pattern = #"Transferred:\s+(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return Int(output[range]) ?? 0
        }
        return 0
    }
    
    private func parseByteCount(from output: String) -> Int64 {
        // rclone stats one-line outputs like: "Transferred: 5.459 MiB / 6.622 MiB, 82%, 0 B/s, ETA -"
        // We look for the part before the first "/"
        let pattern = #"Transferred:\s+([\d.]+)\s*(\w+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let valueRange = Range(match.range(at: 1), in: output),
           let unitRange = Range(match.range(at: 2), in: output) {
            
            let valueStr = String(output[valueRange])
            let unitStr = String(output[unitRange]).lowercased()
            
            if let value = Double(valueStr) {
                let multiplier: Double
                switch unitStr {
                case "b": multiplier = 1
                case "k", "kib": multiplier = 1024
                case "m", "mib": multiplier = 1024 * 1024
                case "g", "gib": multiplier = 1024 * 1024 * 1024
                case "t", "tib": multiplier = 1024 * 1024 * 1024 * 1024
                default: multiplier = 1
                }
                return Int64(value * multiplier)
            }
        }
        return 0
    }
}

struct SyncResult {
    let success: Bool
    let filesTransferred: Int
    let bytesTransferred: Int64
    let duration: TimeInterval
    let error: String?
    
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }
}

/// Deletes bisync held back for the user to allow or undo.
struct PendingDeletes: Codable, Equatable {
    let count: Int
    /// true when files removed on this Mac would be deleted from the remote.
    let onRemote: Bool

    var summary: String {
        "wants to delete \(count) file\(count == 1 ? "" : "s") \(onRemote ? "from Drive" : "from this Mac")"
    }
}

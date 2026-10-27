# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- **No more permanent deletes**: files a sync deletes or overwrites are moved to `99_Archive/_DriveSync Backups/` on the remote and `~/Library/Application Support/GoogleDriveSync/Backups/` locally.
- **Two-way sync safety**: a missing or empty local folder is never synced.
- **Resync recovery**: the resync step now passes `--resync`; retryable errors no longer force a resync.
- **Google Docs/Sheets** are skipped instead of failing the sync or being deleted.
- **Clearer errors**: the menu shows rclone's actual error lines instead of only its summary.
- **Account rename** keeps every remote setting and no longer passes the OAuth token on the command line.

- **Progress bar** fills only while files transfer; listing and comparing show live counts instead of a stuck 100%.
- **Last sync time** in the menu reads as a short relative time with the full date on hover.

### Added
- A warning when a folder syncs with the root of the remote.
- **Per-folder sync intervals**: each folder can follow the default or set its own interval in its Add/Edit sheet.
- **Live sync**: watches the folder and syncs about 30 seconds after local changes settle, and checks the remote every 5 minutes.
- A 5-minute interval option.
- **Ask before large deletes**: when a run would delete more than half of a folder (and more than 10 files), that folder pauses and the menu asks to **Allow** or **Put Back**. Everyday deletes sync without asking.
- **Undo Last Sync** in each folder's menu restores the files the newest run removed, without overwriting newer versions.
- **Backup cleanup**: backups older than 90 days are deleted once a day.
- New two-way folders create their destination on the remote if it doesn't exist.

## [1.1.3] - 2026-03-10

### Added
- **In-App OAuth Flow**: Integrated a browser-based Google Drive authentication flow directly within the app, removing the need for terminal-based rclone setup.
- **Redesigned Add Account Sheet**: A new UI that guides the user through account naming and authentication.
- **Improved Build/Install Logic**: Automated application installation to `/Applications` and launch during deployment.

## [1.1.1] - 2026-03-09

### Added
- **Filtering Support**: Added the ability to exclude specific files and directories from syncing (e.g., `node_modules`, `.git`, `*.tmp`). Includes a new TextEditor UI in the Add/Edit Folder sheets to input ignore patterns.
- **Native Architectures**: Updated the build script (`deploy.sh`) to build separate Apple Silicon (`arm64`) and Intel (`x86_64`) apps instead of a Universal binary, reducing app size and ensuring native performance.
- Added `CHANGELOG.md` to track project updates.

### Fixed
- Fixed an edge case where tracking suffixed volumes (like `/Volumes/media` -> `/Volumes/media-1`) would fail if resolving the original baseline path back from the suffixed path.

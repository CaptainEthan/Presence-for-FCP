# Presence for Final Cut Pro

Presence for Final Cut Pro is a lightweight macOS background agent that mirrors your Final Cut Pro activity to Discord Rich Presence. It reads Final Cut Pro’s preference data to surface the active Library, Event, and Project, and publishes them over Discord IPC using the [`aeddi/DiscordRPC`](https://github.com/aeddi/DiscordRPC) Swift package.

## Features
- Headless background-only app (no UI, no menu bar icon).
- 1-second polling with state-change-only updates to keep CPU under 1% and memory light.
- Uses Final Cut Pro prefs (`FFActiveProjects` / `FFActiveLibraries`, with fallbacks to recent entries) to obtain the current Library/Event/Project.
- Automatically reconnects to Discord; clears presence within 3 seconds if Final Cut Pro closes or crashes.
- Safe fallbacks when data is unavailable (`Unknown Library`, `Unknown Event`, `Timeline Active`).

## Requirements
- macOS 12 or later.
- Discord desktop client installed and running.
- Final Cut Pro (bundle id `com.apple.FinalCut`).
- Read access to Final Cut Pro preference files (no Accessibility permission needed).

## Installation & Build
1. Open `FCPPresence.xcodeproj` in Xcode.
2. Update the Discord client ID in `FCPPresence/AppDelegate.swift` (`discordClientID` constant) if you use your own Discord application.
3. Select a signing team for the `FCPPresence` target if required.
4. Build and run the `FCPPresence` scheme. The app launches as a background agent (no Dock icon).

### Adding the Discord RPC art assets
1. In the [Discord Developer Portal](https://discord.com/developers/applications), open your application.
2. Go to **Rich Presence → Art Assets** and upload a 512×512 (or larger) image.
3. Set **Key** to `fcp` and **Text** to `Final Cut Pro` (these keys are referenced in `AppDelegate.swift`).

## Permissions
- No Accessibility permission is required.
- If you enable App Sandbox manually, ensure the app can read `~/Library/Containers/com.apple.FinalCut/Data/Library/Preferences/com.apple.FinalCut.plist` (and the legacy `~/Library/Preferences/com.apple.FinalCut.plist` if present).

## How it works
- A 1-second `Timer` checks whether Final Cut Pro is running and frontmost.
- Active presence is built from Final Cut Pro prefs:
  - Primary sources: `FFActiveProjects` (bookmark URLs) and `FFActiveLibraries`.
  - Fallbacks: `FFRecentProjects` / `FFRecentLibraries`.
  - If only a library is known, the app scans that library bundle for the most recently modified `CurrentVersion.fcpevent` to infer Event and Project.
- Discord Rich Presence payload:
  - `details`: `Editing: <project>`
  - `state`: `Event: <event> | Library: <library>`
  - `timestamps.start`: Session start time
  - `assets.large_image`: `fcp`
  - `assets.large_text`: `Final Cut Pro`
- When Final Cut Pro is not frontmost, the presence switches to Idle using the last-known names; presence is cleared after a short grace period if Final Cut Pro closes.

## Launching
- Run from Xcode or launch the built `.app`. It stays background-only; to quit, stop it from Xcode or use Activity Monitor.
- Ensure Discord is running; the app silently retries connections every few seconds if Discord is closed.

## Notes
- App Sandbox is disabled by default to allow IPC access to Discord’s Unix domain socket (required by `DiscordRPC`).
- No analytics or external network calls are performed.

# Presence for Final Cut Pro

Presence for Final Cut Pro is a lightweight macOS background agent plus a Final Cut Pro workflow extension that mirrors your editing activity to Discord Rich Presence. It reads live context from Final Cut Pro’s Professional Video Applications APIs (library/event/project/clip/timecode) with a prefs fallback, and publishes them over Discord IPC using the [`aeddi/DiscordRPC`](https://github.com/aeddi/DiscordRPC) Swift package.

## Features
- Headless background agent (no Dock/menu bar icon) with an in-app Final Cut Pro Workflow Extension UI (toggle + Refresh + live context readout).
- 1-second polling with state-change-only updates to keep CPU under 1% and memory light.
- Uses the Professional Video Applications APIs for current library/event/project/clip and timeline timecode; falls back to Final Cut prefs (`FFActiveProjects` / `FFActiveLibraries`) when host data is unavailable.
- Discord presence includes clip/project name, library/event, optional resolution/fps, and timeline timecode.
- Session timer persists while Final Cut Pro stays open (no reset when going idle); presence clears within 3 seconds if Final Cut Pro closes or crashes.
- Safe fallbacks when data is unavailable (`Unknown Library`, `Unknown Event`, `Timeline Active`).

## Requirements
- macOS 12 or later.
- Discord desktop client installed and running.
- Final Cut Pro (bundle id `com.apple.FinalCut`).
- Read access to Final Cut Pro preference files (no Accessibility permission needed).

## Installation & Build
1. Open `FCPPresence.xcodeproj` in Xcode.
2. Update the Discord client ID in `FCPPresence/AppDelegate.swift` (`discordClientID` constant) if you use your own Discord application.
3. Select a signing team for both targets (`FCPPresence` and `FinalCutPresenceExtension`) if required.
4. Build and run the `FCPPresence` scheme. The app launches as a background agent (no Dock icon).
5. In Final Cut Pro, open **Window → Extensions → Presence** to show the workflow extension UI. Use the toggle to enable/disable presence and the Refresh button to request an immediate update; the panel shows the current Library/Event/Project/timecode detected from the host APIs.

### Adding the Discord RPC art assets
1. In the [Discord Developer Portal](https://discord.com/developers/applications), open your application.
2. Go to **Rich Presence → Art Assets** and upload a 512×512 (or larger) image.
3. Set **Key** to `fcp` and **Text** to `Final Cut Pro` (these keys are referenced in `AppDelegate.swift`).

## Permissions
- No Accessibility permission is required.
- If you enable App Sandbox manually, ensure the app can read `~/Library/Containers/com.apple.FinalCut/Data/Library/Preferences/com.apple.FinalCut.plist` (and the legacy `~/Library/Preferences/com.apple.FinalCut.plist` if present).

## How it works
- A 1-second `Timer` checks whether Final Cut Pro is running and frontmost.
- Active presence is built from the Professional Video Applications workflow APIs when available (`FCPXLibrary` / `FCPXEvent` / `FCPXProject`), pulling library/event/project/clip and timeline timecode. If unavailable, it falls back to Final Cut prefs:
  - Primary prefs sources: `FFActiveProjects` (bookmark URLs) and `FFActiveLibraries`.
  - Fallbacks: `FFRecentProjects` / `FFRecentLibraries`.
  - If only a library is known, the app scans that library bundle for the most recently modified `CurrentVersion.fcpevent` to infer Event and Project.
- Discord Rich Presence payload:
  - `details`: `Editing: <clip or project>` (includes timecode when available)
  - `state`: `Event: <event> • Library: <library> • <resolution?> • <fps?>`
  - `timestamps.start`: Session start time (persists while Final Cut Pro stays open)
  - `assets.large_image`: `fcp`
  - `assets.large_text`: `Final Cut Pro`
- When Final Cut Pro is not frontmost, the presence switches to Idle using the last-known names; presence is cleared after a short grace period if Final Cut Pro closes.

## Launching
- Run from Xcode or launch the built `.app`. It stays background-only; to quit, stop it from Xcode or use Activity Monitor.
- Ensure Discord is running; the app silently retries connections every few seconds if Discord is closed.

## Notes
- App Sandbox is disabled by default to allow IPC access to Discord’s Unix domain socket (required by `DiscordRPC`).
- No analytics or external network calls are performed.

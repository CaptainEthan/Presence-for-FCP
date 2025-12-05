# Presence for Final Cut Pro

Presence for Final Cut Pro is a lightweight macOS background agent that mirrors your Final Cut Pro activity to Discord Rich Presence. It watches the active Final Cut Pro window title, extracts the project/timeline name, and publishes it to Discord via IPC using the [`aeddi/DiscordRPC`](https://github.com/aeddi/DiscordRPC) Swift package.

## Features
- Runs headlessly as a background-only app (no windows, no menu bar icon).
- 1-second polling loop with state-change-only updates to keep CPU under 1%.
- Automatically reconnects to Discord if the client is closed or not running.
- Clears presence within 3 seconds if Final Cut Pro closes or crashes.
- Graceful fallbacks when accessibility permission is missing or the window title is empty (`Timeline Active`).

## Requirements
- macOS 12 or later.
- Discord desktop client installed and running.
- Final Cut Pro (bundle id `com.apple.FinalCut`).
- Accessibility permission (to read the Final Cut Pro window title).

## Installation & Build
1. Open `FCPPresence.xcodeproj` in Xcode.
2. Update the Discord client ID in `FCPPresence/AppDelegate.swift` (`discordClientID` constant).
3. Ensure a signing team is selected for the `FCPPresence` target if needed.
4. Build and run the `FCPPresence` scheme. The app launches as a background agent (no Dock icon).

### Adding the Discord RPC art assets
1. In the [Discord Developer Portal](https://discord.com/developers/applications), open your application.
2. Go to **Rich Presence** → **Art Assets** and upload a 512×512 (or larger) image.
3. Set the **Key** to `fcp` and the **Text** to `Final Cut Pro`.  
   This matches the asset keys used in `AppDelegate.swift`.

## Permissions
- On first launch, macOS will prompt for **Accessibility** access when the app tries to read Final Cut Pro window titles.
- If the prompt does not appear or you denied it, go to **System Settings → Privacy & Security → Accessibility**, unlock, and enable `Presence for Final Cut Pro`.
- The app handles missing permission gracefully; Discord presence will remain in the fallback state until permission is granted.

## How it works
- A 1-second `Timer` loop checks whether Final Cut Pro is running and frontmost.
- The focused window title is read via the Accessibility API. Everything after the em dash (`\u{2014}`) is treated as the project/timeline name. If no name is found, `Timeline Active` is used.
- Discord Rich Presence payload:
  - `details`: `Editing in Final Cut Pro`
  - `state`: `Project: <project>`
  - `timestamps.start`: Session start time
  - `assets.large_image`: `fcp`
  - `assets.large_text`: `Final Cut Pro`
- Presence is cleared as soon as Final Cut Pro is inactive or after a 3-second grace period if the app crashes.

## Launching
- Run from Xcode or launch the built `.app`. It stays background-only; to quit, use **Activity Monitor** or run it from Xcode and stop the process.
- Ensure Discord is running; the app will silently retry connections every few seconds if Discord is closed.

## Notes
- App Sandbox is disabled to allow IPC access to Discord’s Unix domain socket (required by `DiscordRPC`).
- No analytics or external network calls are performed.

import Cocoa
import DiscordRPC
import Socket

class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PresenceError: Error {
        case discordSocketUnavailable
    }

    private let discordClientID = "1446513431623631032"
    private let fcpBundleID = "com.apple.FinalCut"
    private let pollInterval: TimeInterval = 1.0
    private let reconnectInterval: TimeInterval = 5.0
    private let presenceClearGrace: TimeInterval = 3.0

    private var rpc: DiscordRPC?
    private var isDiscordConnected = false
    private var nextDiscordReconnect = Date(timeIntervalSince1970: 0)

    private var timer: Timer?
    private var sessionStart: Date?
    private var lastPresenceSignature: String?
    private var lastPresenceActive = false
    private var lastFCPSeenAt: Date?
    private let debugLogging = true
    private var lastFCPFrontmost: Bool?
    private var lastProjectName: String?
    private var lastEventName: String?
    private var lastLibraryName: String?
    private let logFileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FCPPresence.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        prepareDiscordClient()
        timer = Timer.scheduledTimer(timeInterval: pollInterval,
                                     target: self,
                                     selector: #selector(poll),
                                     userInfo: nil,
                                     repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        log("Presence agent launched, polling every \(pollInterval)s")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        clearPresence()
        rpc?.disconnect()
    }

    @objc private func poll() {
        connectDiscordIfNeeded()

        guard let fcpApp = NSRunningApplication.runningApplications(withBundleIdentifier: fcpBundleID).first else {
            if lastFCPFrontmost != false {
                log("Final Cut Pro not running")
            }
            lastFCPFrontmost = false
            handleFCPInactive(isRunning: false)
            return
        }

        let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == fcpBundleID
        if lastFCPFrontmost != isFrontmost {
            log("Final Cut Pro frontmost: \(isFrontmost)")
        }
        lastFCPFrontmost = isFrontmost
        lastFCPSeenAt = Date()

        if isFrontmost {
            sessionStart = sessionStart ?? Date()
            let info = getFCPActiveProjectInfo()
            let libraryName = info.library ?? "Unknown Library"
            let eventName = info.event ?? "Unknown Event"
            let projectName = info.project ?? "Timeline Active"
            updateActivePresence(library: libraryName, event: eventName, project: projectName)
        } else {
            updateIdlePresence()
        }
    }

    private func prepareDiscordClient() {
        rpc = DiscordRPC(clientID: discordClientID)

        rpc?.onConnect { [weak self] _, _ in
            self?.isDiscordConnected = true
            self?.log("Discord RPC connected")
        }

        rpc?.onDisconnect { [weak self] _, _ in
            guard let self else { return }
            self.isDiscordConnected = false
            self.lastPresenceActive = false
            self.nextDiscordReconnect = Date().addingTimeInterval(self.reconnectInterval)
            self.log("Discord RPC disconnected, scheduling reconnect")
        }

        rpc?.onError { [weak self] _, nonce, eventError in
            self?.log("Discord RPC error nonce=\(nonce) code=\(eventError.data.code) msg=\(eventError.data.message)")
        }

        rpc?.onResponse { [weak self] _, nonce, cmd, data in
            guard let self else { return }
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            self.log("Discord RPC response cmd=\(cmd.rawValue) nonce=\(nonce) payload=\(text)")
        }
    }

    private func connectDiscordIfNeeded() {
        guard Date() >= nextDiscordReconnect else { return }
        guard let rpc = rpc else { return }
        guard !isDiscordConnected else { return }

        do {
            try rpc.connect()
            isDiscordConnected = true // optimistic; will be corrected by callbacks
            log("Attempted Discord RPC connect")
        } catch {
            isDiscordConnected = false
            nextDiscordReconnect = Date().addingTimeInterval(reconnectInterval)
            log("Discord RPC connect failed: \(error.localizedDescription)")
        }
    }

    private func updateActivePresence(library: String, event: String, project: String) {
        guard isDiscordConnected else { return }
        let projectName = project.isEmpty ? "Timeline Active" : project
        let libName = library.isEmpty ? "Unknown Library" : library
        let eventName = event.isEmpty ? "Unknown Event" : event
        let signature = "active|\(libName)|\(eventName)|\(projectName)"

        if lastPresenceActive, lastPresenceSignature == signature { return }

        if lastPresenceSignature != signature {
            sessionStart = Date()
        }

        do {
            try rpc?.setPresence(
                details: "Editing: \(projectName)",
                state: "Event: \(eventName) | Library: \(libName)",
                startTimestamp: sessionStart
            )
            lastProjectName = projectName
            lastEventName = eventName
            lastLibraryName = libName
            lastPresenceSignature = signature
            lastPresenceActive = true
            log("Presence updated: \(signature)")
        } catch {
            isDiscordConnected = false
            lastPresenceActive = false
            nextDiscordReconnect = Date().addingTimeInterval(reconnectInterval)
            log("Presence update failed: \(error.localizedDescription)")
        }
    }

    private func updateIdlePresence() {
        guard isDiscordConnected else { return }
        let signature = "IDLE"
        if lastPresenceActive, lastPresenceSignature == signature { return }

        let project = lastProjectName ?? "Inactive"
        let event = lastEventName ?? "Idle"
        let library = lastLibraryName ?? "Final Cut Pro"

        do {
            try rpc?.setPresence(
                details: "Final Cut Pro",
                state: "Idle (\(project)) • Event: \(event) • Library: \(library)",
                startTimestamp: nil
            )
            lastPresenceSignature = signature
            lastPresenceActive = true
            log("Presence updated: \(signature)")
        } catch {
            isDiscordConnected = false
            lastPresenceActive = false
            nextDiscordReconnect = Date().addingTimeInterval(reconnectInterval)
            log("Presence update failed: \(error.localizedDescription)")
        }
    }

    private func clearPresence() {
        guard isDiscordConnected else { return }
        guard lastPresenceActive else { return }

        do {
            try rpc?.clearPresence()
        } catch {
            // Ignore failures; next reconnect will retry
        }

        lastPresenceActive = false
        lastPresenceSignature = nil
        sessionStart = nil
        lastFCPSeenAt = nil
        log("Presence cleared")
    }

    private func handleFCPInactive(isRunning: Bool) {
        if isRunning {
            updateIdlePresence()
            return
        }

        if let lastSeen = lastFCPSeenAt {
            let elapsed = Date().timeIntervalSince(lastSeen)
            if elapsed < presenceClearGrace { return }
        }
        clearPresence()
    }

    func getFCPActiveProjectInfo() -> (library: String?, event: String?, project: String?) {
        let containerPath = ("~/Library/Containers/com.apple.FinalCut/Data/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let legacyPath = ("~/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let prefsPath = FileManager.default.fileExists(atPath: containerPath) ? containerPath : legacyPath

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)) else {
            print("[Presence] Could not read Final Cut preferences")
            return (nil, nil, nil)
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            print("[Presence] Failed to decode plist")
            return (nil, nil, nil)
        }

        if let url = resolveRecentURL(from: plist["FFRecentProjects"]) {
            let parsed = parseProjectInfo(from: url)
            print("[Presence] Library: \(parsed.library ?? "")")
            print("[Presence] Event: \(parsed.event ?? "")")
            print("[Presence] Project: \(parsed.project ?? "")")
            return parsed
        }

        if let libURL = resolveRecentURL(from: plist["FFActiveLibraries"] ?? plist["FFRecentLibraries"]) {
            let name = libURL.deletingPathExtension().lastPathComponent
            print("[Presence] Detected FCP active library: \(name)")
            return (name, nil, nil)
        }

        print("[Presence] No recent projects found in plist")
        return (nil, nil, nil)
    }

    // Read recent FCP project info from Final Cut preferences (FFRecentProjects/FFRecentLibraries)
    func getFCPRecentProjectName() -> String? {
        let containerPath = ("~/Library/Containers/com.apple.FinalCut/Data/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let legacyPath = ("~/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let prefsPath = FileManager.default.fileExists(atPath: containerPath) ? containerPath : legacyPath

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)) else {
            print("[Presence] No Final Cut prefs file found")
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            print("[Presence] Failed to decode Final Cut plist")
            return nil
        }

        if let project = extractName(from: dict["FFRecentProjects"]) {
            print("[Presence] Detected FCP project: \(project)")
            return project
        }

        if let library = extractName(from: dict["FFRecentLibraries"]) {
            print("[Presence] Detected FCP library: \(library)")
            return library
        }

        return nil
    }

    private func extractName(from value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }

        for element in array {
            if let data = element as? Data {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    let name = url.deletingPathExtension().lastPathComponent
                    if !name.isEmpty { return name }
                }
            } else if let path = element as? String {
                let url = URL(fileURLWithPath: path)
                let name = url.deletingPathExtension().lastPathComponent
                if !name.isEmpty { return name }
            } else if let url = element as? URL {
                let name = url.deletingPathExtension().lastPathComponent
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private func resolveRecentURL(from value: Any?) -> URL? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }

        for element in array {
            if let bookmarkData = (element as? [String: Any])?["Bookmark"] as? Data {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                      options: [],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    return url
                }
            } else if let data = element as? Data {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data,
                                      options: [],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    return url
                }
            } else if let path = element as? String {
                return URL(fileURLWithPath: path)
            } else if let url = element as? URL {
                return url
            }
        }
        return nil
    }

    private func parseProjectInfo(from url: URL) -> (library: String?, event: String?, project: String?) {
        let urlNoExt = url.deletingPathExtension()
        let project = urlNoExt.lastPathComponent
        let components = urlNoExt.pathComponents

        var library: String?
        var event: String?

        if let libIndex = components.lastIndex(where: { $0.hasSuffix(".fcpbundle") }) {
            library = components[libIndex].replacingOccurrences(of: ".fcpbundle", with: "")
            let nextIndex = libIndex + 1
            if nextIndex < components.count - 1 {
                let candidate = components[nextIndex]
                if candidate != "Projects.localized" {
                    event = candidate
                } else if nextIndex + 1 < components.count - 1 {
                    event = components[nextIndex + 1]
                }
            }
        }

        return (library, event, project)
    }

    private func log(_ message: String) {
        guard debugLogging else { return }
        let line = "[Presence] \(message)"
        print(line)
        if let data = (line + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) == false {
                FileManager.default.createFile(atPath: logFileURL.path, contents: data, attributes: nil)
            } else if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}

private extension DiscordRPC {
    func setPresence(details: String, state: String, startTimestamp: Date?) throws {
        guard let socket = currentSocketMirror() else {
            throw NSError(domain: "DiscordRPC", code: -1)
        }

        var activity: [String: Any] = [
            "details": details,
            "state": state,
            "assets": [
                "large_image": "fcp",
                "large_text": "Final Cut Pro"
            ],
            "instance": false,
            "type": 0,
            "platform": "desktop"
        ]
        if let startTimestamp {
            activity["timestamps"] = [
                "start": Int(startTimestamp.timeIntervalSince1970)
            ]
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": "sync;\(UUID().uuidString)",
            "args": [
                "activity": activity,
                "pid": ProcessInfo.processInfo.processIdentifier
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try Self.writeOpcodeFrame(payload: data, socket: socket)
    }

    func clearPresence() throws {
        guard let socket = currentSocketMirror() else {
            throw NSError(domain: "DiscordRPC", code: -1)
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": "sync;\(UUID().uuidString)",
            "args": [
                "activity": NSNull(),
                "pid": ProcessInfo.processInfo.processIdentifier
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try Self.writeOpcodeFrame(payload: data, socket: socket)
    }

    private static func writeOpcodeFrame(payload: Data, socket: Socket) throws {
        var buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 8 + payload.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        buffer.storeBytes(of: UInt32(1).littleEndian, as: UInt32.self) // FRAME opcode
        buffer.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: 4, as: UInt32.self)

        payload.withUnsafeBytes { src in
            guard let dstBase = buffer.baseAddress, let srcBase = src.baseAddress else { return }
            dstBase.advanced(by: 8).copyMemory(from: srcBase, byteCount: payload.count)
        }

        try socket.write(from: buffer.baseAddress!, bufSize: buffer.count)
    }

    private func currentSocketMirror() -> Socket? {
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if child.label == "socket" {
                return child.value as? Socket
            }
        }
        return nil
    }
}

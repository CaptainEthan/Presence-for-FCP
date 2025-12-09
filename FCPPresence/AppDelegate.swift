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
    private let presenceToggleNotification = Notification.Name("com.ethanrogers.FCPPresence.toggle")
    private let presenceRefreshNotification = Notification.Name("com.ethanrogers.FCPPresence.refresh")
    private let presenceToggleKey = "enabled"

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
    private var lastClipName: String?
    private var lastTimecode: String?
    private var lastSnapshot: FCPActivitySnapshot?
    private var lastTimelineUpdateAt: Date?
    private var lastActiveBaseSignature: String?
    private var presenceEnabled = true
    private let minTimelineUpdateInterval: TimeInterval = 3.0
    private let fcpMonitor = FCPActivityMonitor()
    private let logFileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FCPPresence.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        registerControlNotifications()
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

    func startFCPDiscordRPC() {
        presenceEnabled = true
        lastPresenceSignature = nil
        lastPresenceActive = false
        poll()
    }

    func stopFCPDiscordRPC() {
        presenceEnabled = false
        clearPresence()
        lastPresenceActive = false
        lastPresenceSignature = nil
        sessionStart = nil
    }

    private func registerControlNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(handlePresenceToggle(_:)),
                           name: presenceToggleNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handlePresenceRefresh),
                           name: presenceRefreshNotification,
                           object: nil)
    }

    @objc private func handlePresenceToggle(_ notification: Notification) {
        let enabled = (notification.userInfo?[presenceToggleKey] as? Bool) ?? true
        log("Presence toggled \(enabled ? "on" : "off") via extension")
        enabled ? startFCPDiscordRPC() : stopFCPDiscordRPC()
    }

    @objc private func handlePresenceRefresh() {
        poll()
    }

    @objc private func poll() {
        guard presenceEnabled else {
            clearPresence()
            lastPresenceActive = false
            lastPresenceSignature = nil
            return
        }
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

        let snapshot = fcpMonitor.fetchActiveContext() ?? getFCPActiveProjectInfo()
        if isFrontmost {
            sessionStart = sessionStart ?? Date()
            let activeSnapshot = snapshot ?? FCPActivitySnapshot(
                library: "Final Cut Pro",
                event: "Unknown Event",
                project: "Timeline Active",
                clipName: "Timeline Active",
                timelineTimecode: nil,
                resolution: nil,
                frameRate: nil
            )
            updateActivePresence(with: activeSnapshot)
        } else {
            if let snapshot { lastSnapshot = snapshot }
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

    private func updateActivePresence(with snapshot: FCPActivitySnapshot) {
        guard isDiscordConnected else { return }
        let projectName = snapshot.project?.isEmpty == false ? snapshot.project! : "Timeline Active"
        let libName = snapshot.library?.isEmpty == false ? snapshot.library! : "Unknown Library"
        let eventName = snapshot.event?.isEmpty == false ? snapshot.event! : "Unknown Event"
        let clipName = snapshot.clipName?.isEmpty == false ? snapshot.clipName! : projectName
        let now = Date()

        let baseSignature = "active|\(libName)|\(eventName)|\(projectName)|\(clipName)"
        let signature = "\(baseSignature)|\(snapshot.timelineTimecode ?? "-")"
        let timecodeChanged = snapshot.timelineTimecode != nil && snapshot.timelineTimecode != lastTimecode
        let timelineThrottled = timecodeChanged && now.timeIntervalSince(lastTimelineUpdateAt ?? .distantPast) < minTimelineUpdateInterval

        if timelineThrottled { return }
        if lastPresenceActive, lastPresenceSignature == signature, !timecodeChanged { return }

        sessionStart = sessionStart ?? Date()

        do {
            var details = "Editing: \(clipName)"
            if let tc = snapshot.timelineTimecode {
                details += " — \(tc)"
            }

            var stateParts = ["Event: \(eventName)", "Library: \(libName)"]
            if let res = snapshot.resolution, !res.isEmpty {
                stateParts.append(res)
            }
            if let fps = snapshot.frameRate, !fps.isEmpty {
                stateParts.append("\(fps) fps")
            }

            try rpc?.setPresence(
                details: details,
                state: stateParts.joined(separator: " • "),
                startTimestamp: sessionStart
            )
            lastProjectName = projectName
            lastEventName = eventName
            lastLibraryName = libName
            lastClipName = clipName
            if timecodeChanged {
                lastTimecode = snapshot.timelineTimecode
                lastTimelineUpdateAt = now
            }
            lastSnapshot = snapshot
            lastPresenceSignature = signature
            lastPresenceActive = true
            lastActiveBaseSignature = baseSignature
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

        if sessionStart == nil {
            sessionStart = Date()
        }
        let project = lastSnapshot?.project ?? lastProjectName ?? "Inactive"
        let event = lastSnapshot?.event ?? lastEventName ?? "Idle"
        let library = lastSnapshot?.library ?? lastLibraryName ?? "Final Cut Pro"
        let clip = lastSnapshot?.clipName ?? project

        do {
            try rpc?.setPresence(
                details: "Final Cut Pro",
                state: "Idle (\(clip)) • Event: \(event) • Library: \(library)",
                startTimestamp: sessionStart
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
        lastTimecode = nil
        lastTimelineUpdateAt = nil
        lastSnapshot = nil
        lastClipName = nil
        lastActiveBaseSignature = nil
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

    func getFCPActiveProjectInfo() -> FCPActivitySnapshot? {
        let containerPath = ("~/Library/Containers/com.apple.FinalCut/Data/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let legacyPath = ("~/Library/Preferences/com.apple.FinalCut.plist" as NSString).expandingTildeInPath
        let prefsPath = FileManager.default.fileExists(atPath: containerPath) ? containerPath : legacyPath

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)) else {
            print("[Presence] Could not read Final Cut preferences")
            return nil
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            print("[Presence] Failed to decode plist")
            return nil
        }

        var libraryURL = resolveRecentURL(from: plist["FFActiveLibraries"] ?? plist["FFRecentLibraries"])
        let projectURL = resolveRecentURL(from: plist["FFActiveProjects"] ?? plist["FFRecentProjects"])

        if let projectURL {
            var parsed = parseProjectInfo(from: projectURL)
            if parsed.library == nil, let libURL = libraryURLFrom(projectURL) {
                parsed.library = libURL.deletingPathExtension().lastPathComponent
                libraryURL = libraryURL ?? libURL
            }

            if (parsed.event == nil || parsed.project == nil), let libURL = libraryURL {
                let derived = deriveLatestProject(in: libURL)
                parsed.event = parsed.event ?? derived.event
                parsed.project = parsed.project ?? derived.project
            }

            print("[Presence] Library: \(parsed.library ?? "")")
            print("[Presence] Event: \(parsed.event ?? "")")
            print("[Presence] Project: \(parsed.project ?? "")")
            return FCPActivitySnapshot(
                library: parsed.library,
                event: parsed.event,
                project: parsed.project,
                clipName: parsed.project,
                timelineTimecode: nil,
                resolution: nil,
                frameRate: nil
            )
        }

        if let libURL = libraryURL {
            let name = libURL.deletingPathExtension().lastPathComponent
            let derived = deriveLatestProject(in: libURL)
            print("[Presence] Detected FCP active library: \(name)")
            return FCPActivitySnapshot(
                library: name,
                event: derived.event,
                project: derived.project,
                clipName: derived.project,
                timelineTimecode: nil,
                resolution: nil,
                frameRate: nil
            )
        }

        print("[Presence] No recent projects found in plist")
        return nil
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

    private func libraryURLFrom(_ url: URL) -> URL? {
        let components = url.pathComponents
        guard let libIndex = components.lastIndex(where: { $0.hasSuffix(".fcpbundle") }) else {
            return nil
        }
        let prefix = Array(components.prefix(libIndex + 1))
        let path = NSString.path(withComponents: prefix)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func normalizeProjectURL(_ url: URL) -> URL {
        let last = url.lastPathComponent
        if last == "CurrentVersion" || last.hasPrefix("CurrentVersion.") {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private func parseProjectInfo(from url: URL) -> (library: String?, event: String?, project: String?) {
        let normalizedURL = normalizeProjectURL(url)
        let components = normalizedURL.pathComponents

        var library: String?
        var event: String?
        var project: String?

        if let libIndex = components.lastIndex(where: { $0.hasSuffix(".fcpbundle") }) {
            library = components[libIndex].replacingOccurrences(of: ".fcpbundle", with: "")
            let nextIndex = libIndex + 1
            if nextIndex < components.count {
                let candidate = components[nextIndex]
                if candidate != "Projects.localized" {
                    event = candidate.replacingOccurrences(of: ".localized", with: "")
                } else if nextIndex + 1 < components.count {
                    event = components[nextIndex + 1].replacingOccurrences(of: ".localized", with: "")
                }
            }

            if let projectsIndex = components.lastIndex(of: "Projects.localized"), projectsIndex + 1 < components.count {
                project = URL(fileURLWithPath: components[projectsIndex + 1]).deletingPathExtension().lastPathComponent
            } else if let last = components.last,
                      last != "Projects.localized",
                      last != components[libIndex],
                      event.map({ last != $0 }) ?? true {
                project = URL(fileURLWithPath: last).deletingPathExtension().lastPathComponent
            }
        }

        return (library, event, project)
    }

    // Walk the active library bundle shallowly to find the most recently modified project
    private func deriveLatestProject(in libraryURL: URL) -> (event: String?, project: String?) {
        let fm = FileManager.default
        var best: (Date, String?, String?)?
        let ignoredTopLevel: Set<String> = [
            "Original Media",
            "Shared Items",
            "Render Files",
            "High Quality Media",
            "High Quality Media.localized",
            "Transcoded Media",
            "Transcoded Media.localized",
            "Analysis Files",
            "Audio Waveforms",
            "Backups",
            ".lock",
            ".lock-info",
            "__Sync__",
            "Settings.plist",
            "CurrentVersion.plist",
            "CurrentVersion.flexolibrary"
        ]

        guard let eventDirs = try? fm.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (nil, nil)
        }

        func considerProject(at projectURL: URL, eventName: String, best: inout (Date, String?, String?)?) {
            var isProjectDir: ObjCBool = false
            guard fm.fileExists(atPath: projectURL.path, isDirectory: &isProjectDir), isProjectDir.boolValue else { return }
            let projectFCPE = projectURL.appendingPathComponent("CurrentVersion.fcpevent")
            if fm.fileExists(atPath: projectFCPE.path),
               let attrs = try? fm.attributesOfItem(atPath: projectFCPE.path),
               let date = attrs[.modificationDate] as? Date {
                let projectName = projectURL.deletingPathExtension().lastPathComponent
                if best == nil || date > (best?.0 ?? .distantPast) {
                    best = (date, eventName, projectName)
                }
            }
        }

        for eventURL in eventDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: eventURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let eventName = eventURL.lastPathComponent.replacingOccurrences(of: ".localized", with: "")
            if ignoredTopLevel.contains(eventURL.lastPathComponent) { continue }

            let eventFCPE = eventURL.appendingPathComponent("CurrentVersion.fcpevent")
            if let attrs = try? fm.attributesOfItem(atPath: eventFCPE.path),
               let date = attrs[.modificationDate] as? Date {
                if best == nil || date > (best?.0 ?? .distantPast) {
                    best = (date, eventName, nil)
                }
            }

            if let projectDirs = try? fm.contentsOfDirectory(
                at: eventURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for projectURL in projectDirs {
                    if projectURL.lastPathComponent == "Projects.localized" {
                        if let nestedProjects = try? fm.contentsOfDirectory(
                            at: projectURL,
                            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            for nested in nestedProjects {
                                considerProject(at: nested, eventName: eventName, best: &best)
                            }
                        }
                        continue
                    }
                    considerProject(at: projectURL, eventName: eventName, best: &best)
                }
            }
        }

        if let best = best {
            return (best.1, best.2)
        }
        return (nil, nil)
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

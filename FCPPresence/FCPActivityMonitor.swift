import Foundation
import AppKit
#if canImport(ProExtensionHost)
import ProExtensionHost
#endif

/// Lightweight reader that pulls the active Final Cut Pro context via the Professional Video Applications APIs.
/// Uses runtime selectors so the code continues to work across minor host changes while still preferring the real workflow APIs.
struct FCPActivitySnapshot: Equatable {
    let library: String?
    let event: String?
    let project: String?
    let clipName: String?
    let timelineTimecode: String?
    let resolution: String?
    let frameRate: String?
}

final class FCPActivityMonitor {
    private let bundleIdentifier = "com.apple.FinalCut"
    private var lastSnapshot: FCPActivitySnapshot?

    func isFCPRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first != nil
    }

    /// Returns the most recent context pulled from the active FCP session, if accessible.
    /// Falls back to the last cached value when FCP is not frontmost or the workflow API is temporarily unavailable.
    func fetchActiveContext() -> FCPActivitySnapshot? {
        guard isFCPRunning() else {
            lastSnapshot = nil
            return nil
        }

        #if canImport(ProExtensionHost)
        guard let host = ProExtensionHostSingleton() as? NSObject else { return lastSnapshot }
        guard let library = object(for: ["activeLibrary"], in: host) else { return lastSnapshot }

        let event = object(for: ["activeEvent"], in: library)
        let project = object(for: ["activeProject"], in: event) ?? object(for: ["activeProject"], in: library)
        let timeline = object(for: ["timeline", "sequence"], in: project)
        let playhead = object(for: ["playhead"], in: timeline)

        let libraryName = string(for: ["name", "displayName"], in: library)
        let eventName = string(for: ["name", "displayName"], in: event)
        let projectName = string(for: ["name", "displayName"], in: project)
        let timecode = string(for: ["timecodeString", "timecode"], in: playhead)
            ?? string(for: ["timecodeString", "timecode"], in: timeline)
        let clip = object(for: ["selectedClip", "currentClip"], in: timeline)
        let clipName = string(for: ["displayName", "name"], in: clip)
            ?? string(for: ["displayName", "name"], in: project)
        let resolution = string(for: ["resolutionString", "projectResolution", "videoResolution"], in: project)
        let frameRate = string(for: ["frameRateString", "projectFrameRate", "videoFrameRate"], in: project)

        let snapshot = FCPActivitySnapshot(
            library: libraryName,
            event: eventName,
            project: projectName,
            clipName: clipName,
            timelineTimecode: timecode,
            resolution: resolution,
            frameRate: frameRate
        )
        lastSnapshot = snapshot
        return snapshot
        #else
        return lastSnapshot
        #endif
    }

    private func object(for keys: [String], in object: NSObject?) -> NSObject? {
        guard let object else { return nil }
        for key in keys {
            let selector = NSSelectorFromString(key)
            if object.responds(to: selector),
               let value = object.perform(selector)?.takeUnretainedValue() as? NSObject {
                return value
            }
        }
        return nil
    }

    private func string(for keys: [String], in object: NSObject?) -> String? {
        guard let object else { return nil }
        for key in keys {
            let selector = NSSelectorFromString(key)
            if object.responds(to: selector),
               let value = object.perform(selector)?.takeUnretainedValue() {
                if let string = value as? String, !string.isEmpty {
                    return string
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return nil
    }
}

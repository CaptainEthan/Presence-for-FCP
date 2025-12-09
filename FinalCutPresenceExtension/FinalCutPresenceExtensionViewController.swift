import Cocoa
import ProExtensionHost

@objc class FinalCutPresenceExtensionViewController: NSViewController {
    private let toggleNotification = Notification.Name("com.ethanrogers.FCPPresence.toggle")
    private let refreshNotification = Notification.Name("com.ethanrogers.FCPPresence.refresh")
    private let toggleKey = "enabled"

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Presence for Final Cut Pro")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        return label
    }()

    private lazy var hostLabel: NSTextField = {
        let label = NSTextField(labelWithString: currentHostInfo())
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var toggleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Discord presence")
        label.font = .systemFont(ofSize: 13)
        return label
    }()

    private lazy var presenceSwitch: NSSwitch = {
        let control = NSSwitch()
        control.state = .on
        control.target = self
        control.action = #selector(toggleChanged(_:))
        return control
    }()

    private lazy var refreshButton: NSButton = {
        let button = NSButton(title: "Refresh Presence", target: self, action: #selector(refreshTapped(_:)))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Ready")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var contextLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Waiting for Final Cut Pro…")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        return label
    }()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    override func awakeFromNib() {
        super.awakeFromNib()
    }

    override var nibName: NSNib.Name? {
        NSNib.Name("FinalCutPresenceExtensionViewController")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        refreshContext()
    }

    private func buildInterface() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let toggleRow = NSStackView(views: [toggleLabel, presenceSwitch])
        toggleRow.alignment = .centerY
        toggleRow.orientation = .horizontal
        toggleRow.spacing = 8

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(hostLabel)
        let contextTitle = NSTextField(labelWithString: "Active Context")
        contextTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(contextTitle)
        root.addArrangedSubview(contextLabel)
        root.addArrangedSubview(toggleRow)
        root.addArrangedSubview(refreshButton)
        root.addArrangedSubview(statusLabel)

        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            contextLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        DistributedNotificationCenter.default().post(name: toggleNotification, object: nil, userInfo: [toggleKey: enabled])
        updateStatus(enabled ? "Presence enabled" : "Presence paused")
    }

    @objc private func refreshTapped(_ sender: NSButton) {
        DistributedNotificationCenter.default().post(name: refreshNotification, object: nil)
        refreshContext()
        updateStatus("Refresh requested at \(timeFormatter.string(from: Date()))")
    }

    private func currentHostInfo() -> String {
        guard let host = ProExtensionHostSingleton() as? FCPXHost else {
            return "Final Cut Pro"
        }
        return "\(host.name) \(host.versionString)"
    }

    private func updateStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func refreshContext() {
        contextLabel.stringValue = activeContextDescription()
    }

    private func activeContextDescription() -> String {
        guard let host = ProExtensionHostSingleton() as? NSObject else {
            return "Final Cut Pro not available."
        }
        guard let library = object(for: ["activeLibrary"], in: host) else {
            return "No active library detected."
        }

        let libraryName = string(for: ["displayName", "name"], in: library) ?? "Unknown Library"
        let event = object(for: ["activeEvent"], in: library)
        let eventName = string(for: ["displayName", "name"], in: event) ?? "Unknown Event"
        let project = object(for: ["activeProject"], in: event) ?? object(for: ["activeProject"], in: library)
        let projectName = string(for: ["displayName", "name"], in: project) ?? "Timeline Active"
        let timeline = object(for: ["timeline", "sequence"], in: project)
        let playhead = object(for: ["playhead"], in: timeline)
        let timecode = string(for: ["timecodeString", "timecode"], in: playhead)
            ?? string(for: ["timecodeString", "timecode"], in: timeline)

        var lines: [String] = []
        lines.append("Library: \(libraryName)")
        lines.append("Event: \(eventName)")
        lines.append("Project: \(projectName)")
        if let timecode {
            lines.append("Timeline: \(timecode)")
        }
        return lines.joined(separator: "\n")
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

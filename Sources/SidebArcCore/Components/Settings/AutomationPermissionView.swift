import AppKit

/// Settings › Permissions: Automation status for the browsers SidebArc may ask
/// about open tabs, a hint when a click found it missing, and one button that
/// asks macOS (or opens System Settings when it was denied).
///
/// Renders from `update(...)`; the owning view controller does the checks.
final class AutomationPermissionView: NSView {
    struct Entry: Equatable {
        let name: String
        let permission: AutomationPermission
    }

    var onAllow: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Automation (switch to open tabs)")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let allowButton = SettingsActionButton(title: "Allow Browser Access…")

    private static let secondaryTextColor = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = ThemeConstants.Colors.darkGray
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = Self.secondaryTextColor
        allowButton.target = self
        allowButton.action = #selector(allowTapped)

        let stack = NSStackView(views: [titleLabel, statusLabel, allowButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ThemeConstants.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            allowButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            allowButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    /// `hintBrowserName`: a click couldn't look for open tabs in this browser.
    func update(entries: [Entry], hintBrowserName: String?) {
        var lines: [String] = []
        if let hintBrowserName {
            lines.append("A click couldn’t look for open tabs in \(hintBrowserName), so it opened a new tab.")
        }
        if entries.isEmpty {
            lines.append("No profile uses a browser that can report its tabs (Chrome, Brave or Safari).")
        }
        for entry in entries {
            lines.append("\(entry.name): \(Self.describe(entry.permission))")
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
        allowButton.isHidden = !entries.contains { $0.permission == .notDetermined || $0.permission == .denied }
    }

    static func describe(_ permission: AutomationPermission) -> String {
        switch permission {
        case .granted: return "✓ allowed"
        case .denied: return "✗ not allowed (turn it on in System Settings › Privacy & Security › Automation)"
        case .notDetermined: return "not asked yet"
        case .notRunning: return "not running (open it to check)"
        case .other(let code): return "unknown (\(code))"
        }
    }

    @objc private func allowTapped() {
        onAllow?()
    }
}

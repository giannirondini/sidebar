import AppKit

final class WorkspaceRowView: BaseView {
    struct Style {
        // Layout
        var rowCornerRadius: CGFloat
        var handleSize: CGFloat
        var colorSquareSize: CGFloat
        var colorSquareBorderWidth: CGFloat
        var colorSquareCornerRadius: CGFloat
        var deleteButtonSize: CGFloat
        var profileLabelMaxWidth: CGFloat

        // Spacing
        var handleLeading: CGFloat
        var colorSquareLeading: CGFloat
        var titleLeading: CGFloat
        var titleTrailing: CGFloat
        var buttonsTrailing: CGFloat
        var buttonGap: CGFloat

        // Typography
        var titleFont: NSFont
        var titleColor: NSColor
        var setProfileFont: NSFont

        // Colors
        var handleTintColor: NSColor
        var colorSquareBorderColor: NSColor
        var deleteTintColor: NSColor
        var profileLabelColor: NSColor
        var setProfileTextColor: NSColor
        var setProfileBorderColor: NSColor
        var hoverBackgroundColor: NSColor

        // Handle icon
        var handleIconName: String
        var handleIconSize: CGFloat
        var handleIconWeight: NSFont.Weight

        // Delete icon
        var deleteIconName: String
        var deleteIconSize: CGFloat
        var deleteIconWeight: NSFont.Weight

        // Profile name (non-hovered indicator)
        var profileLabelFont: NSFont

        // Set profile button
        var setProfileCornerRadius: CGFloat
        var setProfileBorderWidth: CGFloat
        var setProfilePaddingH: CGFloat
        var setProfileHeight: CGFloat

        static var `default`: Style {
            let baseColorValue: CGFloat = 20.0 / 255.0

            return Style(
                rowCornerRadius: ThemeConstants.CornerRadius.large,
                handleSize: ThemeConstants.Sizing.iconMedium,
                colorSquareSize: ThemeConstants.Sizing.iconMedium,
                colorSquareBorderWidth: 1.5,
                colorSquareCornerRadius: ThemeConstants.CornerRadius.small,
                deleteButtonSize: 20,
                profileLabelMaxWidth: 110,
                handleLeading: 12,
                colorSquareLeading: ThemeConstants.Spacing.small,
                titleLeading: ThemeConstants.Spacing.medium,
                titleTrailing: ThemeConstants.Spacing.small,
                buttonsTrailing: ThemeConstants.Spacing.regular,
                buttonGap: ThemeConstants.Spacing.small,
                titleFont: ThemeConstants.Fonts.bodyRegular,
                titleColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.high),
                setProfileFont: ThemeConstants.Fonts.systemFont(size: 11, weight: .medium),
                handleTintColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.low),
                colorSquareBorderColor: NSColor(calibratedRed: baseColorValue, green: baseColorValue, blue: baseColorValue, alpha: ThemeConstants.Opacity.subtle),
                deleteTintColor: NSColor.black.withAlphaComponent(0.5),
                profileLabelColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.medium),
                setProfileTextColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.medium),
                setProfileBorderColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.subtle),
                hoverBackgroundColor: NSColor.black.withAlphaComponent(ThemeConstants.Opacity.extraSubtle),
                handleIconName: "line.3.horizontal",
                handleIconSize: ThemeConstants.Sizing.iconMedium,
                handleIconWeight: .medium,
                deleteIconName: "xmark",
                deleteIconSize: ThemeConstants.Sizing.iconSmall,
                deleteIconWeight: .bold,
                profileLabelFont: ThemeConstants.Fonts.systemFont(size: 11, weight: .medium),
                setProfileCornerRadius: ThemeConstants.CornerRadius.small,
                setProfileBorderWidth: 1,
                setProfilePaddingH: ThemeConstants.Spacing.small,
                setProfileHeight: 22
            )
        }
    }

    private let handleView = NSImageView()
    private let colorSquare = NSView()
    /// The space's emoji or symbol, shown in place of the colour square when set.
    private let iconView = NSImageView()
    private let editableTitle = InlineEditableTextField()
    private let profileLabel = NSTextField(labelWithString: "")
    private let setProfileButton: PaddedTextButton
    private let deleteButton = NSButton()
    private var style: Style = .default
    private var onDelete: (() -> Void)?
    private var onProfile: (() -> Void)?
    private var hasProfile: Bool { !profileLabel.stringValue.isEmpty }

    // Dynamic title trailing constraints (mutually exclusive)
    private var titleTrailingToEdge: NSLayoutConstraint!
    private var titleTrailingToProfileIcon: NSLayoutConstraint!
    private var titleTrailingToSetProfile: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        let s = Style.default
        setProfileButton = PaddedTextButton(hPadding: s.setProfilePaddingH)
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        let s = Style.default
        setProfileButton = PaddedTextButton(hPadding: s.setProfilePaddingH)
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        layer?.cornerRadius = style.rowCornerRadius
        layer?.masksToBounds = true

        // Handle icon
        handleView.translatesAutoresizingMaskIntoConstraints = false
        handleView.imageScaling = .scaleProportionallyDown
        let handleConfig = NSImage.SymbolConfiguration(pointSize: style.handleIconSize, weight: style.handleIconWeight)
        handleView.image = NSImage(systemSymbolName: style.handleIconName, accessibilityDescription: "Drag to reorder")?
            .withSymbolConfiguration(handleConfig)
        handleView.contentTintColor = style.handleTintColor

        // Color square
        colorSquare.translatesAutoresizingMaskIntoConstraints = false
        colorSquare.wantsLayer = true
        colorSquare.layer?.cornerRadius = style.colorSquareCornerRadius
        colorSquare.layer?.masksToBounds = true
        colorSquare.layer?.borderWidth = style.colorSquareBorderWidth
        colorSquare.layer?.borderColor = style.colorSquareBorderColor.cgColor

        // Title field
        editableTitle.translatesAutoresizingMaskIntoConstraints = false
        editableTitle.font = style.titleFont
        editableTitle.textColor = style.titleColor
        editableTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Profile name (visible when not hovered + several profiles)
        profileLabel.translatesAutoresizingMaskIntoConstraints = false
        profileLabel.font = style.profileLabelFont
        profileLabel.textColor = style.profileLabelColor
        profileLabel.lineBreakMode = .byTruncatingTail
        profileLabel.alignment = .right
        profileLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        profileLabel.setContentHuggingPriority(.required, for: .horizontal)
        profileLabel.isHidden = true

        // "Set profile..." text button (visible on hover)
        setProfileButton.translatesAutoresizingMaskIntoConstraints = false
        setProfileButton.title = "Set Profile"
        setProfileButton.bezelStyle = .texturedRounded
        setProfileButton.isBordered = false
        setProfileButton.font = style.setProfileFont
        setProfileButton.contentTintColor = style.setProfileTextColor
        setProfileButton.wantsLayer = true
        setProfileButton.layer?.cornerRadius = style.setProfileCornerRadius
        setProfileButton.layer?.borderWidth = style.setProfileBorderWidth
        setProfileButton.layer?.borderColor = style.setProfileBorderColor.cgColor
        setProfileButton.target = self
        setProfileButton.action = #selector(handleProfileAction)
        setProfileButton.setButtonType(.momentaryChange)
        setProfileButton.isHidden = true
        setProfileButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Delete button (visible on hover)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.isBordered = false
        let deleteIconConfig = NSImage.SymbolConfiguration(pointSize: style.deleteIconSize, weight: style.deleteIconWeight)
        deleteButton.image = NSImage(systemSymbolName: style.deleteIconName, accessibilityDescription: "Delete space")?
            .withSymbolConfiguration(deleteIconConfig)
        deleteButton.contentTintColor = style.deleteTintColor
        deleteButton.target = self
        deleteButton.action = #selector(handleDeleteAction)
        deleteButton.setButtonType(.momentaryChange)
        deleteButton.isHidden = true

        addSubview(handleView)
        addSubview(colorSquare)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)
        addSubview(editableTitle)
        addSubview(profileLabel)
        addSubview(setProfileButton)
        addSubview(deleteButton)

        // Three mutually exclusive title trailing constraints
        titleTrailingToEdge = editableTitle.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -style.buttonsTrailing)
        titleTrailingToProfileIcon = editableTitle.trailingAnchor.constraint(
            lessThanOrEqualTo: profileLabel.leadingAnchor, constant: -style.titleTrailing)
        titleTrailingToSetProfile = editableTitle.trailingAnchor.constraint(
            lessThanOrEqualTo: setProfileButton.leadingAnchor, constant: -style.titleTrailing)

        NSLayoutConstraint.activate([
            // Handle icon
            handleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.handleLeading),
            handleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            handleView.widthAnchor.constraint(equalToConstant: style.handleSize),
            handleView.heightAnchor.constraint(equalToConstant: style.handleSize),

            // Color square
            colorSquare.leadingAnchor.constraint(equalTo: handleView.trailingAnchor, constant: style.colorSquareLeading),
            colorSquare.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorSquare.widthAnchor.constraint(equalToConstant: style.colorSquareSize),
            colorSquare.heightAnchor.constraint(equalToConstant: style.colorSquareSize),
            iconView.centerXAnchor.constraint(equalTo: colorSquare.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: colorSquare.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: style.colorSquareSize),
            iconView.heightAnchor.constraint(equalToConstant: style.colorSquareSize),

            // Title (leading + center only, trailing is dynamic)
            editableTitle.leadingAnchor.constraint(equalTo: colorSquare.trailingAnchor, constant: style.titleLeading),
            editableTitle.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Profile name (at trailing edge, shown when not hovered + several profiles)
            profileLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.buttonsTrailing),
            profileLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            profileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: style.profileLabelMaxWidth),

            // "Set profile..." button (to the left of delete, shown on hover)
            setProfileButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -style.buttonGap),
            setProfileButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            setProfileButton.heightAnchor.constraint(equalToConstant: style.setProfileHeight),

            // Delete button (at trailing edge, shown on hover)
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.buttonsTrailing),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: style.deleteButtonSize),
            deleteButton.heightAnchor.constraint(equalToConstant: style.deleteButtonSize),
        ])
    }

    func configure(workspaceName: String,
                   workspaceColor: NSColor,
                   icon: CustomIcon?,
                   canDelete: Bool,
                   profileName: String?,
                   profileDetail: String?,
                   onDelete: (() -> Void)?,
                   onProfile: (() -> Void)?) {
        if editableTitle.isEditing {
            if editableTitle.text != workspaceName {
                cancelInlineRename()
                editableTitle.text = workspaceName
            }
        } else {
            editableTitle.text = workspaceName
        }

        colorSquare.layer?.backgroundColor = workspaceColor.cgColor
        let iconImage = icon.flatMap { SpaceIconView.image(for: $0, size: style.colorSquareSize) }
        iconView.image = iconImage
        iconView.contentTintColor = iconImage?.isTemplate == true ? style.titleColor : nil
        iconView.isHidden = iconImage == nil
        colorSquare.isHidden = iconImage != nil
        deleteButton.isEnabled = canDelete
        deleteButton.toolTip = canDelete ? nil : "Cannot delete the last space"

        profileLabel.stringValue = profileName ?? ""
        profileLabel.toolTip = profileDetail
        self.onDelete = onDelete
        self.onProfile = onProfile
        updateVisualState()
    }

    var isInlineRenaming: Bool {
        editableTitle.isEditing
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        editableTitle.beginInlineRename(onCommit: onCommit, onCancel: onCancel)
    }

    func cancelInlineRename() {
        editableTitle.cancelInlineRename()
    }

    @objc private func handleDeleteAction() {
        onDelete?()
    }

    @objc private func handleProfileAction() {
        onProfile?()
    }

    override func handleHoverStateChanged() {
        updateVisualState()
    }

    private func updateVisualState() {
        // Deactivate all title trailing constraints first
        titleTrailingToEdge.isActive = false
        titleTrailingToProfileIcon.isActive = false
        titleTrailingToSetProfile.isActive = false

        if isHovered {
            // Hovered: show "Set profile..." button + X, hide the profile name
            profileLabel.isHidden = true
            setProfileButton.isHidden = false
            deleteButton.isHidden = false
            titleTrailingToSetProfile.isActive = true
        } else if hasProfile {
            // Not hovered, several profiles: show the profile name only
            profileLabel.isHidden = false
            setProfileButton.isHidden = true
            deleteButton.isHidden = true
            titleTrailingToProfileIcon.isActive = true
        } else {
            // Not hovered, no profile: nothing on right
            profileLabel.isHidden = true
            setProfileButton.isHidden = true
            deleteButton.isHidden = true
            titleTrailingToEdge.isActive = true
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ThemeConstants.Animation.durationFast
            context.timingFunction = ThemeConstants.Animation.timingFunction

            if isHovered {
                layer?.backgroundColor = style.hoverBackgroundColor.cgColor
                setProfileButton.animator().alphaValue = 1.0
                deleteButton.animator().alphaValue = 1.0
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                if hasProfile {
                    profileLabel.animator().alphaValue = 1.0
                }
                setProfileButton.animator().alphaValue = 0.0
                deleteButton.animator().alphaValue = 0.0
            }
        })
    }
}

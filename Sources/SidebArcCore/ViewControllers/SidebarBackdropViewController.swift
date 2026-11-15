import AppKit

/// The window's root view controller: a behind-window blur with the main view on
/// top. A space colour below 100% opacity then shows a frosted view of what's behind
/// the sidebar instead of sharp, unreadable windows; an opaque colour covers the blur
/// entirely, so it never needs switching on or off (space transitions just work).
///
/// The colour is painted once, on `MainViewController.view.layer` (the window's own
/// background is clear): painting it on both used to stack the opacity (0.92 + 0.92
/// showed as 0.99).
final class SidebarBackdropViewController: NSViewController {
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        // The sidebar is rarely the key window (the browser is): keep the blur, not
        // the flat inactive look.
        blur.state = .active
        view = blur

        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: blur.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
    }
}

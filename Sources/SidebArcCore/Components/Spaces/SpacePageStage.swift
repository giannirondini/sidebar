import AppKit

/// Where a space transition draws its pages: a layer-hosting view over the space
/// page, holding the outgoing and incoming pages as plain image layers.
///
/// Why not move the real page: AppKit owns the layers of the views it lays out and
/// can reset their `transform` (observed in a test window right after layout, and in
/// the app as the old list flashing at x = 0 when a switch landed). Layers in a
/// layer-hosting view belong to us, so their transforms stay put.
///
/// Never takes clicks; the transition hides the live page while the stage is up.
@MainActor
final class SpacePageStage: NSView {
    /// The page being left (moves with the offset).
    let outgoing = CALayer()
    /// The page being revealed, placed one page to the side (moves with the offset).
    let incoming = CALayer()

    /// Bumped on every `begin`, so a fade scheduled by an earlier landing can tell
    /// that a new transition has taken the stage over.
    private(set) var generation = 0
    /// Used only before the stage is in a window (it always is during a transition).
    private static let fallbackScale: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Layer-hosting: assign the layer before wantsLayer.
        let host = CALayer()
        host.masksToBounds = true
        layer = host
        wantsLayer = true
        for page in [outgoing, incoming] {
            // No implicit animations: only the transition's explicit ones move pages.
            page.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                            "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
            page.contentsGravity = .resize
            host.addSublayer(page)  // incoming last: on top (the Reduce Motion crossfade)
        }
        host.actions = ["opacity": NSNull(), "hidden": NSNull()]
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the stage with `image` (the current page) in place; no incoming page yet.
    func begin(outgoing image: NSImage?) {
        generation += 1
        removeAllPageAnimations()
        layer?.removeAllAnimations()
        layer?.opacity = 1
        setContents(of: outgoing, to: image)
        place(outgoing, at: 0)
        outgoing.opacity = 1
        setIncoming(nil, baseX: 0)
        isHidden = false
    }

    /// The incoming page and where it sits when the offset is 0 (one page to the side).
    func setIncoming(_ image: NSImage?, baseX: CGFloat) {
        setContents(of: incoming, to: image)
        place(incoming, at: baseX)
        incoming.opacity = 1
        incoming.isHidden = image == nil
    }

    /// Moves both pages by `offset` at once (tracking).
    func setOffset(_ offset: CGFloat) {
        let transform = CATransform3DMakeTranslation(offset, 0, 0)
        outgoing.transform = transform
        incoming.transform = transform
    }

    func removeAllPageAnimations() {
        outgoing.removeAllAnimations()
        incoming.removeAllAnimations()
    }

    /// Fades the stage out over the live page (drawn by now) and hides it, unless
    /// a new transition took the stage over in the meantime.
    func fadeOut(duration: TimeInterval) {
        let started = generation
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == started else { return }
            self.hideNow()
        }
        layer?.opacity = 0
        layer?.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    func hideNow() {
        isHidden = true
        layer?.removeAllAnimations()
        layer?.opacity = 1
        removeAllPageAnimations()
        outgoing.contents = nil
        incoming.contents = nil
    }

    /// Puts a page at `x` with no offset. The transform is cleared first: setting a
    /// layer's `frame` while it is transformed (by the previous transition) silently
    /// shifts it by the inverse, and every page after the first landed off-screen.
    private func place(_ page: CALayer, at x: CGFloat) {
        page.transform = CATransform3DIdentity
        page.frame = bounds.offsetBy(dx: x, dy: 0)
    }

    private func setContents(of page: CALayer, to image: NSImage?) {
        guard let image else {
            page.contents = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? Self.fallbackScale
        page.contentsScale = image.recommendedLayerContentsScale(scale)
        page.contents = image.layerContents(forContentsScale: page.contentsScale)
    }
}

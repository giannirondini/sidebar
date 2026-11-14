import AppKit
import os

/// One space switch in progress (Phase 3a.5).
///
/// The live content and a snapshot of the target space sit side by side in the
/// swipe clip and move by the same offset: 1:1 with the finger while tracking,
/// then a spring (`SpaceSwipe.Spring`) to the end. The background colour and the
/// space bar's pill follow the same progress and the same spring. A swipe, a
/// space bar click and ⌘⌥←/→ all go through here.
@MainActor
final class SpaceTransition {
    enum Phase {
        case tracking
        case settling(commits: Bool)
    }

    let fromWorkspace: Workspace
    let fromIndex: Int
    /// The space being revealed; nil past the first or last space (rubber band).
    var target: (workspace: Workspace, index: Int)?
    /// +1: the target is on the left (finger right, previous space); -1: on the right.
    var side: CGFloat = 1
    var previewView: NSView?
    /// Snapshots taken during this transition, so a drag that wiggles across its
    /// start doesn't render the same space again.
    var snapshots: [UUID: NSView] = [:]
    /// Current horizontal offset of the content (points).
    var offset: CGFloat = 0
    var phase: Phase = .tracking
    /// System "Reduce motion": nothing slides; a switch crossfades instead.
    let reducesMotion: Bool

    init(fromWorkspace: Workspace, fromIndex: Int) {
        self.fromWorkspace = fromWorkspace
        self.fromIndex = fromIndex
        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension MainViewController: SwipeGestureServiceDelegate {
    private static let transitionAnimationKey = "spaceTransition"
    private static let transitionLogger = Logger(subsystem: AppIdentity.logSubsystem, category: "transition")

    // MARK: - Gesture

    func swipeGestureDidBegin(_ service: SwipeGestureService) {
        // A new gesture during a settle: land the previous switch first.
        if spaceTransition != nil {
            finishSpaceTransitionNow()
        }
    }

    func swipeGestureDidUpdate(_ service: SwipeGestureService, translationX: CGFloat) {
        trackSpaceSwipe(translation: translationX)
    }

    func swipeGestureDidCancel(_ service: SwipeGestureService) {
        endSpaceSwipe(translation: 0, velocity: 0, forceStay: true)
    }

    func swipeGestureDidEnd(_ service: SwipeGestureService, translationX: CGFloat, velocityX: CGFloat) {
        endSpaceSwipe(translation: translationX, velocity: velocityX, forceStay: false)
    }

    // MARK: - Input during a transition

    /// While a page slides, AppKit still hit-tests the old space's views (a layer
    /// transform doesn't move a view's frame) and the model still selects the old
    /// space. So any click or key lands the transition first; the event then
    /// reaches the new space. Local monitors run before the event is dispatched.
    func installTransitionInputMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            if let self, self.spaceTransition != nil {
                self.finishSpaceTransitionNow()
            }
            return event
        }
    }

    // MARK: - Entry points

    /// A click on a space bar icon or ⌘⌥←/→: slide to `id` with the same spring as
    /// a swipe. Instant (no transition) from Settings, for the current space, or
    /// while the window isn't visible.
    func requestSpaceSwitch(to id: UUID) {
        if spaceTransition != nil {
            finishSpaceTransitionNow()
        }
        let workspaces = model.workspaces
        guard !model.isSettingsShown,
              view.window?.isVisible == true,
              let fromIndex = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }),
              let toIndex = workspaces.firstIndex(where: { $0.id == id }),
              fromIndex != toIndex
        else {
            model.selectWorkspace(id: id)
            return
        }
        removeLandingCover()
        let transition = SpaceTransition(fromWorkspace: workspaces[fromIndex], fromIndex: fromIndex)
        spaceTransition = transition
        // A rename belongs to the space being left (and would show in the snapshot).
        spaceHeader.cancelInlineRename()
        // Further away than one space still slides one page, from its side.
        prepareTarget(of: transition, target: (workspaces[toIndex], toIndex), side: toIndex < fromIndex ? 1 : -1)
        settle(transition, commits: true, releaseVelocity: 0)
    }

    private func trackSpaceSwipe(translation: CGFloat) {
        guard !model.isSettingsShown else { return }
        if let transition = spaceTransition, case .settling = transition.phase {
            finishSpaceTransitionNow()
        }
        let transition: SpaceTransition
        if let existing = spaceTransition {
            transition = existing
        } else {
            let workspaces = model.workspaces
            guard let index = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) else { return }
            removeLandingCover()
            transition = SpaceTransition(fromWorkspace: workspaces[index], fromIndex: index)
            spaceTransition = transition
            spaceHeader.cancelInlineRename()
        }

        let width = swipeClipContainer.bounds.width
        let side: CGFloat = translation >= 0 ? 1 : -1
        let workspaces = model.workspaces
        let targetIndex = transition.fromIndex - Int(side)
        let target = workspaces.indices.contains(targetIndex) ? (workspaces[targetIndex], targetIndex) : nil
        if target?.1 != transition.target?.index || side != transition.side {
            prepareTarget(of: transition, target: target, side: side)
        }

        // Reduce Motion: the page doesn't follow the finger; the release decides.
        guard !transition.reducesMotion else { return }
        let offset = target == nil
            ? SpaceSwipe.rubberBand(translation, dimension: width)
            : max(-width, min(width, translation))
        apply(offset: offset, to: transition)
    }

    private func endSpaceSwipe(translation: CGFloat, velocity: CGFloat, forceStay: Bool) {
        guard let transition = spaceTransition, case .tracking = transition.phase else { return }
        let outcome = forceStay ? .stay : SpaceSwipe.outcome(
            translation: translation,
            velocity: velocity,
            width: swipeClipContainer.bounds.width,
            canGoPrevious: transition.fromIndex > 0,
            canGoNext: transition.fromIndex < model.workspaces.count - 1
        )
        let commits = outcome != .stay && transition.target != nil
        // Past the ends the page doesn't follow the finger 1:1, so the release speed doesn't apply.
        settle(transition, commits: commits, releaseVelocity: transition.target == nil ? 0 : velocity)
    }

    // MARK: - Moving the page

    /// Places a snapshot of `target` next to the content, on `side`; removes any
    /// previous one. `target == nil` (past an end) shows nothing there.
    private func prepareTarget(of transition: SpaceTransition, target: (Workspace, Int)?, side: CGFloat) {
        transition.previewView?.removeFromSuperview()
        transition.previewView = nil
        transition.side = side
        transition.target = target.map { (workspace: $0.0, index: $0.1) }
        guard let workspace = target?.0 else { return }

        let preview = transition.snapshots[workspace.id] ?? makeSpaceSnapshotView(for: workspace)
        transition.snapshots[workspace.id] = preview
        let width = swipeClipContainer.bounds.width
        preview.frame.origin = NSPoint(x: -side * width, y: 0)
        preview.layer?.transform = CATransform3DMakeTranslation(transition.offset, 0, 0)
        swipeClipContainer.addSubview(preview, positioned: .below, relativeTo: workspaceContentStack)
        transition.previewView = preview
    }

    /// Tracking: moves the page, the colour and the pill to `offset` at once.
    private func apply(offset: CGFloat, to transition: SpaceTransition) {
        transition.offset = offset
        let progress = self.progress(of: transition)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeTranslation(offset, 0, 0)
        workspaceContentStack.layer?.transform = transform
        transition.previewView?.layer?.transform = transform
        view.layer?.backgroundColor = blendedBackground(transition, progress: progress).cgColor
        pinnedTabsView.layer?.opacity = Float(changesFavorites(transition) ? 1 - progress : 1)
        CATransaction.commit()
        spaceBar.setSelectionProgress(toward: transition.target?.workspace.id, progress: progress)
    }

    /// Whether the target space shows other Favorites (another profile): only then
    /// do they fade with the page; otherwise they stay still.
    private func changesFavorites(_ transition: SpaceTransition) -> Bool {
        guard let target = transition.target?.workspace else { return false }
        return target.profileId != transition.fromWorkspace.profileId
    }

    /// How far the page is toward the target, 0…1 (0 past an end).
    private func progress(of transition: SpaceTransition) -> CGFloat {
        let width = swipeClipContainer.bounds.width
        guard transition.target != nil, width > 0 else { return 0 }
        return min(1, abs(transition.offset) / width)
    }

    private func blendedBackground(_ transition: SpaceTransition, progress: CGFloat) -> NSColor {
        let from = transition.fromWorkspace.colorId.backgroundColor
        guard let to = transition.target?.workspace.colorId.backgroundColor, progress > 0 else { return from }
        return from.usingColorSpace(.sRGB)?.blended(withFraction: progress, of: to.usingColorSpace(.sRGB) ?? to) ?? to
    }

    /// Springs the page (and colour and pill) from where it is to the target
    /// (`commits`) or back. All animations start in one transaction, so they stay in step.
    private func settle(_ transition: SpaceTransition, commits: Bool, releaseVelocity: CGFloat) {
        transition.phase = .settling(commits: commits)
        if transition.reducesMotion {
            return crossfade(transition, commits: commits)
        }
        let width = swipeClipContainer.bounds.width
        let start = transition.offset
        let end = commits ? transition.side * width : 0
        let spring = SpaceSwipe.Spring.standard
        let initialVelocity = spring.initialVelocity(releaseVelocity: releaseVelocity, remaining: end - start)

        func springAnimation(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = spring.stiffness
            animation.damping = spring.damping
            animation.initialVelocity = initialVelocity
            animation.fromValue = from
            animation.toValue = to
            animation.duration = animation.settlingDuration
            return animation
        }

        let startColor = blendedBackground(transition, progress: progress(of: transition))
        let endColor = commits
            ? transition.target?.workspace.colorId.backgroundColor ?? startColor
            : transition.fromWorkspace.colorId.backgroundColor
        let pillSpaceId = commits ? transition.target?.workspace.id : transition.fromWorkspace.id

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak transition] in
            guard let self, let transition, self.spaceTransition === transition else { return }
            self.finish(transition)
        }
        // Final values first (layout passes keep them), then the explicit springs.
        let endTransform = CATransform3DMakeTranslation(end, 0, 0)
        for layer in [workspaceContentStack.layer, transition.previewView?.layer].compactMap({ $0 }) {
            layer.transform = endTransform
            layer.add(springAnimation("transform.translation.x", from: start, to: end), forKey: Self.transitionAnimationKey)
        }
        view.layer?.backgroundColor = endColor.cgColor
        view.layer?.add(springAnimation("backgroundColor", from: startColor.cgColor, to: endColor.cgColor),
                        forKey: Self.transitionAnimationKey)
        if let pillSpaceId {
            spaceBar.settleSelection(on: pillSpaceId) { from, to in
                springAnimation("transform.translation.x", from: from, to: to)
            }
        }
        if let favoritesLayer = pinnedTabsView.layer {
            let startOpacity = favoritesLayer.presentation()?.opacity ?? favoritesLayer.opacity
            // Another profile's Favorites fade out with the page and fade in on landing.
            let endOpacity: Float = commits && changesFavorites(transition) ? 0 : 1
            favoritesLayer.opacity = endOpacity
            if startOpacity != endOpacity {
                favoritesLayer.add(springAnimation("opacity", from: startOpacity, to: endOpacity),
                                   forKey: Self.transitionAnimationKey)
            }
        }
        CATransaction.commit()
        transition.offset = end
    }

    /// Reduce Motion: the target's page fades in over the current one in place;
    /// the colour (and another profile's Favorites) fade with it; the pill jumps on landing.
    private func crossfade(_ transition: SpaceTransition, commits: Bool) {
        guard commits, let preview = transition.previewView, let target = transition.target?.workspace else {
            return finish(transition)
        }
        func fade(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = ThemeConstants.Animation.durationNormal
            animation.timingFunction = ThemeConstants.Animation.timingFunction
            return animation
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak transition] in
            guard let self, let transition, self.spaceTransition === transition else { return }
            self.finish(transition)
        }
        // Over the content, in place.
        preview.removeFromSuperview()
        preview.frame.origin = .zero
        swipeClipContainer.addSubview(preview, positioned: .above, relativeTo: workspaceContentStack)
        preview.layer?.transform = CATransform3DIdentity
        preview.layer?.opacity = 1
        preview.layer?.add(fade("opacity", from: 0, to: 1), forKey: Self.transitionAnimationKey)

        let startColor = transition.fromWorkspace.colorId.backgroundColor
        let endColor = target.colorId.backgroundColor
        view.layer?.backgroundColor = endColor.cgColor
        view.layer?.add(fade("backgroundColor", from: startColor.cgColor, to: endColor.cgColor), forKey: Self.transitionAnimationKey)

        if changesFavorites(transition), let favoritesLayer = pinnedTabsView.layer {
            favoritesLayer.opacity = 0
            favoritesLayer.add(fade("opacity", from: 1, to: 0), forKey: Self.transitionAnimationKey)
        }
        CATransaction.commit()
    }

    /// Lands the current transition immediately (a new click or gesture arrived):
    /// a settle jumps to its end, a drag still being tracked goes back.
    func finishSpaceTransitionNow() {
        guard let transition = spaceTransition else { return }
        if case .tracking = transition.phase {
            transition.phase = .settling(commits: false)
        }
        finish(transition)
    }

    private func finish(_ transition: SpaceTransition) {
        let commits: Bool
        if case .settling(let value) = transition.phase { commits = value } else { commits = false }

        workspaceContentStack.layer?.removeAnimation(forKey: Self.transitionAnimationKey)
        view.layer?.removeAnimation(forKey: Self.transitionAnimationKey)
        pinnedTabsView.layer?.removeAnimation(forKey: Self.transitionAnimationKey)
        let fadeInFavorites = commits && changesFavorites(transition)
        // On a switch the target's snapshot stays over the content, in place, until
        // the reloaded list has drawn (`collectionView.reloadData()` only rebuilds
        // rows on the next layout and display); otherwise the old list shows for a
        // frame and the new one pops in.
        let cover = commits ? transition.previewView : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        workspaceContentStack.layer?.transform = CATransform3DIdentity
        if let cover {
            cover.layer?.removeAnimation(forKey: Self.transitionAnimationKey)
            cover.removeFromSuperview()
            cover.frame.origin = .zero
            cover.layer?.transform = CATransform3DIdentity
            cover.layer?.opacity = 1
            swipeClipContainer.addSubview(cover, positioned: .above, relativeTo: workspaceContentStack)
        } else {
            transition.previewView?.removeFromSuperview()
        }
        CATransaction.commit()
        spaceBar.endSelectionTransition()

        // Unless something else changed the selection meanwhile (a new space, the
        // agent API): that change wins. Still "in transition" here, so the
        // selection's own reload is held rather than run twice.
        if commits, let target = transition.target, model.currentWorkspace.id == transition.fromWorkspace.id {
            model.selectWorkspace(id: target.workspace.id)
        }
        spaceTransition = nil
        if commits || reloadHeldByTransition {
            reloadHeldByTransition = false
            // After a switch the page already slid (and the snapshot covers the
            // reload); a cancelled swipe's held change goes through the normal diff.
            suppressNodeAnimations = commits
            reloadData()
            suppressNodeAnimations = false
        }
        if commits {
            // The snapshot showed the new space from the top; land there too.
            let clipView = nodeListViewController.scrollView.contentView
            clipView.scroll(to: .zero)
            nodeListViewController.scrollView.reflectScrolledClipView(clipView)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pinnedTabsView.layer?.opacity = 1
        if fadeInFavorites {
            // The new profile's grid (possibly another height) is in place: fade it in.
            pinnedTabsView.layer?.add(fade(from: 0, to: 1), forKey: Self.transitionAnimationKey)
        }
        CATransaction.commit()

        if let cover {
            landingCover = cover
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            // Next turn of the run loop: the list's new rows are on screen by then.
            // The fade hides any pixel the snapshot and the live list don't share.
            DispatchQueue.main.async { [weak self] in
                guard self?.landingCover === cover else { return }
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    cover.removeFromSuperview()
                    if self?.landingCover === cover { self?.landingCover = nil }
                }
                cover.layer?.opacity = 0
                cover.layer?.add(Self.fade(from: 1, to: 0), forKey: Self.transitionAnimationKey)
                CATransaction.commit()
            }
        }
    }

    /// A new transition starts: the previous landing's snapshot must not linger over it.
    private func removeLandingCover() {
        landingCover?.removeFromSuperview()
        landingCover = nil
    }

    private func fade(from: Float, to: Float) -> CABasicAnimation {
        Self.fade(from: from, to: to)
    }

    private static func fade(from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = ThemeConstants.Animation.durationFast
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    // MARK: - Snapshot of a space's page

    /// A bitmap of `workspace`'s page (header, scheduled links, list, bottom row),
    /// rendered in the real content views and then restored. The model is not touched.
    private func makeSpaceSnapshotView(for workspace: Workspace) -> NSView {
        let started = CACurrentMediaTime()
        let current = model.currentWorkspace
        let clipView = nodeListViewController.scrollView.contentView
        let savedScroll = clipView.bounds.origin

        renderSpaceContent(workspace)
        clipView.scroll(to: .zero)
        workspaceContentStack.layoutSubtreeIfNeeded()
        let bounds = workspaceContentStack.bounds
        var image: NSImage?
        if let bitmap = workspaceContentStack.bitmapImageRepForCachingDisplay(in: bounds) {
            workspaceContentStack.cacheDisplay(in: bounds, to: bitmap)
            image = NSImage(size: bounds.size)
            image?.addRepresentation(bitmap)
        }

        renderSpaceContent(current)
        workspaceContentStack.layoutSubtreeIfNeeded()
        clipView.scroll(to: savedScroll)
        nodeListViewController.scrollView.reflectScrolledClipView(clipView)

        let milliseconds = (CACurrentMediaTime() - started) * 1000
        let rows = workspace.items.count
        Self.transitionLogger.debug("snapshot of a space with \(rows, privacy: .public) top-level items took \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")

        let container = SnapshotView(frame: NSRect(origin: .zero, size: swipeClipContainer.bounds.size))
        container.wantsLayer = true
        let imageView = NSImageView(frame: container.bounds)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignTopLeft
        imageView.image = image
        container.addSubview(imageView)
        return container
    }

    /// Shows `workspace`'s page content in the content views (what `reloadData`
    /// shows for the current space), without animation.
    private func renderSpaceContent(_ workspace: Workspace) {
        let searching = searchCoordinator.isSearchActive
        configureSpaceHeader(for: workspace)
        if searching {
            scheduledLinksAccordion.isHidden = true
        } else {
            scheduledLinksAccordion.update(entries: model.scheduledLinks(in: workspace.id))
        }
        nodeListViewController.workspaceColor = workspace.colorId
        let items = searching ? workspace.items : ScheduledLinkFiltering.hideScheduled(workspace.items)
        nodeListViewController.reloadData(with: searchCoordinator.filter(nodes: items), forceExpand: searching, animated: false)
    }
}

/// A space page snapshot. Never takes clicks: while it fades out over the live
/// content after a switch, clicks must reach the real list underneath.
private final class SnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

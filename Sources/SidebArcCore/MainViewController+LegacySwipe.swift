import AppKit

// The original snapshot-based swipe (pre-Phase 3a.5), kept verbatim behind
// `defaults write io.github.giannirondini.sidebarc legacySpaceTransition -bool YES`
// until the new transition is accepted; then this file is deleted.

// MARK: - SwipeGestureServiceDelegate

extension MainViewController: SwipeGestureServiceDelegate {

    func swipeGestureDidBegin(_ service: SwipeGestureService) {
        guard !isSwipeAnimating else { return }
        workspaceContentStack.layer?.removeAllAnimations()
        removeSwipePreview()
    }

    func swipeGestureDidUpdate(_ service: SwipeGestureService, translationX: CGFloat) {
        guard !isSwipeAnimating else { return }
        guard let layer = workspaceContentStack.layer else { return }

        let canGoRight = canNavigatePrevious()  // finger right = previous
        let canGoLeft = canNavigateNext()        // finger left = next

        var clampedX = translationX
        // Apply rubber-band dampening if no adjacent workspace in that direction
        if translationX > 0 && !canGoRight {
            clampedX = translationX * 0.7
        } else if translationX < 0 && !canGoLeft {
            clampedX = translationX * 0.7
        }

        // Capture preview snapshot on first significant movement
        let direction: SwipeDirection = translationX > 0 ? .right : .left
        if swipePreviewSnapshot == nil || swipePreviewDirection != direction {
            capturePreviewSnapshot(for: direction)
        }

        // Show/update preview of adjacent workspace
        updateSwipePreview(translationX: clampedX, direction: direction)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(clampedX, 0, 0)
        CATransaction.commit()
    }

    func swipeGestureDidComplete(_ service: SwipeGestureService, direction: SwipeDirection) {
        guard !isSwipeAnimating else { return }
        guard let layer = workspaceContentStack.layer else { return }

        let containerWidth = swipeClipContainer.bounds.width
        let containerHeight = swipeClipContainer.bounds.height

        // Determine if we can actually navigate
        let canNavigate: Bool
        switch direction {
        case .right: canNavigate = canNavigatePrevious()
        case .left: canNavigate = canNavigateNext()
        }

        guard canNavigate else {
            animateSpringBounce()
            return
        }

        isSwipeAnimating = true

        // Save current color so applyWorkspaceStyling can animate the transition
        let currentBgColor: NSColor
        if model.isSettingsShown {
            currentBgColor = ThemeConstants.Colors.settingsBackground
        } else {
            currentBgColor = model.currentWorkspace.colorId.backgroundColor
        }

        // --- Snapshot-based animation ---
        // Capture a snapshot of the current workspace content at its current drag position
        let currentSnapshotView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
        currentSnapshotView.wantsLayer = true
        let contentBounds = workspaceContentStack.bounds
        if let bitmap = workspaceContentStack.bitmapImageRepForCachingDisplay(in: contentBounds) {
            workspaceContentStack.cacheDisplay(in: contentBounds, to: bitmap)
            let image = NSImage(size: contentBounds.size)
            image.addRepresentation(bitmap)
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignTopLeft
            imageView.image = image
            currentSnapshotView.addSubview(imageView)
        }

        // Build the incoming snapshot from the already-captured preview
        let incomingSnapshotView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
        incomingSnapshotView.wantsLayer = true
        if let previewImage = swipePreviewSnapshot {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignTopLeft
            imageView.image = previewImage
            incomingSnapshotView.addSubview(imageView)
        }

        // Capture current drag offset before resetting
        let currentOffset = layer.presentation()?.transform.m41 ?? layer.transform.m41
        let slideOffX: CGFloat = direction == .right ? containerWidth : -containerWidth
        let incomingStartX: CGFloat = direction == .right ? currentOffset - containerWidth : currentOffset + containerWidth

        // Remove the drag preview and reset the real content layer
        removeSwipePreview()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        // Hide the real content and place snapshots in the clip container
        workspaceContentStack.isHidden = true

        currentSnapshotView.frame.origin.x = currentOffset
        incomingSnapshotView.frame.origin.x = incomingStartX
        swipeClipContainer.addSubview(currentSnapshotView)
        swipeClipContainer.addSubview(incomingSnapshotView)

        // Animate both snapshots: current slides out, incoming slides in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ThemeConstants.Animation.durationNormal
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            currentSnapshotView.animator().frame.origin.x = slideOffX
            incomingSnapshotView.animator().frame.origin.x = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }

            // Remove snapshots
            currentSnapshotView.removeFromSuperview()
            incomingSnapshotView.removeFromSuperview()

            // Set the from-color so reloadData → applyWorkspaceStyling animates the color
            self.swipeColorAnimationFromColor = currentBgColor

            // Suppress collection view animations — we already animated via snapshots
            self.suppressNodeAnimations = true

            // Suppress async onChange to prevent extra reload
            let savedOnChange = self.model.onChange
            self.model.onChange = nil

            // Switch workspace
            switch direction {
            case .right: self.navigateToPreviousWorkspace()
            case .left: self.navigateToNextWorkspace()
            }

            // Synchronously update UI with new workspace data
            self.reloadData()

            // Restore onChange for future state changes
            self.model.onChange = savedOnChange

            // Show the real content (now displaying new workspace)
            self.workspaceContentStack.isHidden = false
            self.suppressNodeAnimations = false
            self.isSwipeAnimating = false
        })
    }

    func swipeGestureDidCancel(_ service: SwipeGestureService) {
        animateSnapBack()
    }

    // MARK: - Swipe Helpers

    private func canNavigatePrevious() -> Bool {
        // Swipe disabled from/to settings — only between workspaces
        if model.isSettingsShown { return false }
        let workspaces = model.workspaces
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) else { return false }
        return currentIndex > 0
    }

    private func canNavigateNext() -> Bool {
        // Swipe disabled from/to settings — only between workspaces
        if model.isSettingsShown { return false }
        let workspaces = model.workspaces
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) else { return false }
        return currentIndex < workspaces.count - 1
    }

    private func animateSnapBack() {
        guard let layer = workspaceContentStack.layer else { return }
        isSwipeAnimating = true

        let containerWidth = swipeClipContainer.bounds.width
        let containerHeight = swipeClipContainer.bounds.height
        let currentOffset = layer.presentation()?.transform.m41 ?? layer.transform.m41

        // Capture snapshot of current workspace content
        let contentSnapshotView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
        contentSnapshotView.wantsLayer = true
        let contentBounds = workspaceContentStack.bounds
        if let bitmap = workspaceContentStack.bitmapImageRepForCachingDisplay(in: contentBounds) {
            workspaceContentStack.cacheDisplay(in: contentBounds, to: bitmap)
            let image = NSImage(size: contentBounds.size)
            image.addRepresentation(bitmap)
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignTopLeft
            imageView.image = image
            contentSnapshotView.addSubview(imageView)
        }

        // Build snapshot of adjacent workspace preview
        let previewSnapshotView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
        previewSnapshotView.wantsLayer = true
        if let previewImage = swipePreviewSnapshot {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignTopLeft
            imageView.image = previewImage
            previewSnapshotView.addSubview(imageView)
        }

        // Reset real content and remove preview
        removeSwipePreview()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        workspaceContentStack.isHidden = true

        // Position snapshots at current visual positions
        contentSnapshotView.frame.origin.x = currentOffset
        let previewStartX: CGFloat = currentOffset > 0
            ? currentOffset - containerWidth  // preview is to the left
            : currentOffset + containerWidth   // preview is to the right
        previewSnapshotView.frame.origin.x = previewStartX

        swipeClipContainer.addSubview(previewSnapshotView)
        swipeClipContainer.addSubview(contentSnapshotView)

        // Animate: content slides back to origin, preview slides off-screen
        let previewEndX: CGFloat = currentOffset > 0 ? -containerWidth : containerWidth
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ThemeConstants.Animation.durationFast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            contentSnapshotView.animator().frame.origin.x = 0
            previewSnapshotView.animator().frame.origin.x = previewEndX
        }, completionHandler: { [weak self] in
            contentSnapshotView.removeFromSuperview()
            previewSnapshotView.removeFromSuperview()
            self?.workspaceContentStack.isHidden = false
            self?.isSwipeAnimating = false
        })
    }

    /// Spring bounce used when swiping at an edge with no adjacent workspace.
    private func animateSpringBounce() {
        guard let layer = workspaceContentStack.layer else { return }
        isSwipeAnimating = true

        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = layer.transform.m41
        spring.toValue = 0
        spring.mass = 1.0
        spring.stiffness = 400
        spring.damping = 22
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        spring.isRemovedOnCompletion = false
        spring.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            layer.removeAnimation(forKey: "springBounce")
            layer.transform = CATransform3DIdentity
            self?.isSwipeAnimating = false
            self?.removeSwipePreview()
        }
        layer.add(spring, forKey: "springBounce")
        CATransaction.commit()
    }

    // MARK: - Swipe Preview

    private func adjacentWorkspace(for direction: SwipeDirection) -> Workspace? {
        // Swipe only between workspaces, not to/from settings
        if model.isSettingsShown { return nil }
        let workspaces = model.workspaces
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) else { return nil }
        switch direction {
        case .right:
            return currentIndex > 0 ? workspaces[currentIndex - 1] : nil
        case .left:
            return currentIndex < workspaces.count - 1 ? workspaces[currentIndex + 1] : nil
        }
    }

    /// Captures a bitmap snapshot of the adjacent workspace's content by temporarily
    /// switching the model and rendering the content views (without animations).
    private func capturePreviewSnapshot(for direction: SwipeDirection) {
        swipePreviewSnapshot = nil
        swipePreviewDirection = direction

        guard let nextWorkspace = adjacentWorkspace(for: direction) else { return }

        let currentId = model.currentWorkspace.id

        // Suppress onChange to prevent external UI updates
        let savedOnChange = model.onChange
        model.onChange = nil

        // Switch to the adjacent workspace and update views without animation
        model.selectWorkspace(id: nextWorkspace.id)
        pinnedTabsView.update(pinnedLinks: model.profile(for: nextWorkspace).favorites)
        configureSpaceHeader(for: nextWorkspace)
        scheduledLinksAccordion.update(entries: model.scheduledLinks(in: nextWorkspace.id))
        let filteredNodes = searchCoordinator.filter(nodes: ScheduledLinkFiltering.hideScheduled(nextWorkspace.items))
        nodeListViewController.reloadData(with: filteredNodes, forceExpand: false, animated: false)

        // Force layout so the views render with new data
        workspaceContentStack.layoutSubtreeIfNeeded()

        // Capture bitmap
        let bounds = workspaceContentStack.bounds
        if let bitmap = workspaceContentStack.bitmapImageRepForCachingDisplay(in: bounds) {
            workspaceContentStack.cacheDisplay(in: bounds, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            swipePreviewSnapshot = image
        }

        // Restore original workspace and content without animation
        model.selectWorkspace(id: currentId)
        let currentWorkspace = model.currentWorkspace
        pinnedTabsView.update(pinnedLinks: model.currentProfile.favorites)
        configureSpaceHeader(for: currentWorkspace)
        scheduledLinksAccordion.update(entries: model.scheduledLinks(in: currentWorkspace.id))
        let currentNodes = searchCoordinator.filter(nodes: ScheduledLinkFiltering.hideScheduled(currentWorkspace.items))
        nodeListViewController.reloadData(with: currentNodes, forceExpand: searchCoordinator.isSearchActive, animated: false)
        workspaceContentStack.layoutSubtreeIfNeeded()

        // Restore onChange
        model.onChange = savedOnChange
    }

    private func updateSwipePreview(translationX: CGFloat, direction: SwipeDirection) {
        let containerWidth = swipeClipContainer.bounds.width
        let containerHeight = swipeClipContainer.bounds.height

        // Use the CURRENT workspace's background color so the preview blends seamlessly
        let currentBgColor: NSColor
        if model.isSettingsShown {
            currentBgColor = ThemeConstants.Colors.settingsBackground
        } else {
            currentBgColor = model.currentWorkspace.colorId.backgroundColor
        }

        if swipePreviewView == nil {
            let preview = NSView()
            preview.wantsLayer = true
            swipeClipContainer.addSubview(preview, positioned: .below, relativeTo: workspaceContentStack)
            swipePreviewView = preview
        }

        guard let preview = swipePreviewView else { return }

        // Same background as current workspace — color change happens via fade after switch
        preview.layer?.backgroundColor = currentBgColor.cgColor

        // Position preview adjacent to the sliding content
        if translationX > 0 {
            preview.frame = NSRect(x: translationX - containerWidth, y: 0, width: containerWidth, height: containerHeight)
        } else {
            preview.frame = NSRect(x: containerWidth + translationX, y: 0, width: containerWidth, height: containerHeight)
        }

        // Add or update the content snapshot image view
        let imageView: NSImageView
        if let existing = preview.subviews.first(where: { $0 is NSImageView }) as? NSImageView {
            imageView = existing
        } else {
            imageView = NSImageView()
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignTopLeft
            preview.addSubview(imageView)
        }
        imageView.image = swipePreviewSnapshot
        imageView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
    }

    private func removeSwipePreview() {
        swipePreviewView?.removeFromSuperview()
        swipePreviewView = nil
        swipePreviewSnapshot = nil
        swipePreviewDirection = nil
    }
}

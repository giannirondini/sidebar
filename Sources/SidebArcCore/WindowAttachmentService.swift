//
//  WindowAttachmentService.swift
//  SidebArc
//
//  Service for attaching SidebArc window to browser windows using macOS Accessibility API.
//

import AppKit
import os
@preconcurrency import ApplicationServices

@MainActor
protocol WindowAttachmentServiceDelegate: AnyObject {
    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool)
    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService)
    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService)
    /// Width of the attached sidebar (the user's, kept within the window's limits).
    func attachmentServiceSidebarWidth(_ service: WindowAttachmentService) -> CGFloat
}

@MainActor
final class WindowAttachmentService {
    static let shared = WindowAttachmentService()
    /// `/usr/bin/log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc" AND category == "attach"'`
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "attach")

    weak var delegate: WindowAttachmentServiceDelegate?

    // State tracking
    private var browserApp: NSRunningApplication?
    private var browserWindowElement: AXUIElement?
    private var observers: [AXObserver] = []
    private var appObserver: AXObserver?
    private var appObserverPid: pid_t?
    private var isEnabled: Bool = false
    /// Browsers the sidebar attaches to (lowercased bundle ids): every profile's
    /// browser and the global default (`attachmentBrowserIds`).
    private var browserBundleIds: Set<String> = []
    /// The one it follows now: the frontmost browser in `browserBundleIds`.
    private var attachedBundleId: String?
    private var sidebarPosition: SidebarPosition = .right
    private var lastFrontmostBundleId: String?

    // Notification observers
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?

    // Debouncing - reduced from 0.05 to 0.016 (~60fps) for smoother tracking
    private var positionUpdateTimer: Timer?

    /// Waits for the first window of a browser that came to the front without one
    /// (it is still launching). Its "focused window changed" notification can't be
    /// relied on: the observer is registered before the app is ready (log
    /// 2026-11-15: Chrome launched from a favorite never re-attached).
    private var windowRetryTimer: Timer?
    private static let windowRetryInterval: TimeInterval = 0.25
    private static let windowRetryTimeout: TimeInterval = 10
    private let positionDebounceInterval: TimeInterval = 0.016

    // Frame caching to skip redundant updates
    private var lastBrowserFrame: NSRect?
    private var lastSidebarFrame: NSRect?

    // Screen caching to reduce detection overhead
    private var cachedScreen: NSScreen?
    private var cachedScreenFrame: NSRect?

    // Smooth animation using NSAnimationContext
    private var isAnimating: Bool = false

    private init() {}

    // MARK: - Public Interface

    func enable(browserBundleIds: [String], position: SidebarPosition) {
        guard checkAccessibilityPermissions() else {
            logger.notice("Accessibility not granted")
            requestAccessibilityPermissions()
            return
        }

        logger.notice("Enabled for \(browserBundleIds, privacy: .public), position \(position.rawValue, privacy: .public)")

        self.browserBundleIds = Set(browserBundleIds.map { $0.lowercased() })
        self.sidebarPosition = position
        self.isEnabled = true

        setupWorkspaceObservers()
        setupScreenChangeObserver()
        attachToBrowser()
    }

    /// Replaces the set of browsers (profiles or the default browser changed). A
    /// no-op when it is the same set. Never hides the sidebar: the change usually
    /// comes from Settings, shown in the sidebar itself. If the followed browser
    /// left the set it is just dropped; the next app activation decides.
    func updateBrowsers(_ bundleIds: [String]) {
        let next = Set(bundleIds.map { $0.lowercased() })
        guard isEnabled, next != browserBundleIds else { return }
        browserBundleIds = next
        if let attachedBundleId, !next.contains(attachedBundleId) {
            detachFromBrowser()
        }
        if isAttachable(BrowserManager.frontmostApp()?.bundleIdentifier) {
            attachToBrowser()
        }
    }

    func forceUpdate() {
        guard isEnabled else { return }
        updateSidebarPosition(forceShow: true)
    }

    func disable() {
        cancelWindowRetry()
        logger.notice("Disabled")

        isEnabled = false
        cleanupObservers()
        cleanupAppObserver()
        cleanupWorkspaceObservers()
        cleanupScreenChangeObserver()

        browserApp = nil
        browserWindowElement = nil
        browserBundleIds = []
        attachedBundleId = nil
        lastBrowserFrame = nil
        lastSidebarFrame = nil
        lastFrontmostBundleId = nil
    }

    func checkAccessibilityPermissions() -> Bool {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermissions() {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Browser Window Discovery

    /// Polls until `app` (frontmost, attachable, no window yet) shows a window, then
    /// attaches with a fresh window-focus observer. Gives up after the timeout, or as
    /// soon as `app` is no longer frontmost (another activation decides then).
    private func waitForFirstWindow(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        let deadline = Date().addingTimeInterval(Self.windowRetryTimeout)
        let timer = Timer(timeInterval: Self.windowRetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      Date() < deadline else {
                    self?.cancelWindowRetry()
                    return
                }
                guard self.findFrontmostBrowserWindow(activeApp: app) != nil else { return }
                self.logger.notice("First window of pid \(pid) appeared: attach")
                // Registered while the app was launching, the observer may be dead.
                self.cleanupAppObserver()
                self.attachToBrowser()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowRetryTimer = timer
    }

    private func cancelWindowRetry() {
        windowRetryTimer?.invalidate()
        windowRetryTimer = nil
    }

    /// Hides the sidebar, logging why (the reason helps with flicker reports).
    private func hide(_ reason: String) {
        logger.notice("Hide: \(reason, privacy: .public)")
        delegate?.attachmentServiceShouldHideWindow(self)
    }

    // MARK: - Decisions (pure, tested)

    /// The browsers to attach to: each profile's browser (an uninstalled one falls
    /// back like `BrowserManager.resolveTarget`) and the global default; per-link
    /// overrides are not included. Unique, compared case-insensitively, in order.
    static func attachmentBrowserIds(
        profiles: [Profile],
        globalDefault: String?,
        installed: (String) -> Bool
    ) -> [String] {
        let candidates = profiles.map {
            BrowserManager.resolveTarget(link: nil, profile: $0, globalDefault: globalDefault, installed: installed).bundleId
        } + [globalDefault]
        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { seen.insert($0.lowercased()).inserted }
    }

    enum ActivationDecision: Equatable {
        /// A browser in the set came to the front: attach to it.
        case attach
        /// SidebArc itself came to the front right after a browser in the set (a
        /// click on the sidebar): stay visible.
        case keepVisible
        case hide
    }

    nonisolated static func activationDecision(
        activated: String?,
        previous: String?,
        ownBundleId: String?,
        browsers: Set<String>
    ) -> ActivationDecision {
        func isBrowser(_ id: String?) -> Bool { id.map { browsers.contains($0.lowercased()) } ?? false }
        if isBrowser(activated) { return .attach }
        if let activated, activated == ownBundleId {
            return isBrowser(previous) ? .keepVisible : .hide
        }
        return .hide
    }

    /// A browser instance that hasn't finished launching while another instance of
    /// the same browser runs: the short-lived process LaunchServices starts to open a
    /// link in a browser profile (`createsNewApplicationInstance`). It activates with
    /// no window, hands the URL over and quits; the running instance activates right
    /// after. Attaching to it hid the sidebar for a moment on every such link (seen
    /// in the "attach" log: "no window found … launched false", then the real pid).
    nonisolated static func isTransientInstance(pid: pid_t, finishedLaunching: Bool, sameBrowserPids: [pid_t]) -> Bool {
        !finishedLaunching && sameBrowserPids.contains { $0 != pid }
    }

    private func isAttachable(_ bundleId: String?) -> Bool {
        bundleId.map { browserBundleIds.contains($0.lowercased()) } ?? false
    }

    /// Drops the followed browser's window and app observers.
    private func detachFromBrowser() {
        cancelWindowRetry()
        cleanupObservers()
        cleanupAppObserver()
        browserApp = nil
        browserWindowElement = nil
        attachedBundleId = nil
    }

    private func findFrontmostBrowserWindow(activeApp: NSRunningApplication? = nil) -> AXUIElement? {
        guard let bundleId = attachedBundleId else { return nil }

        let app: NSRunningApplication
        if let activeApp = activeApp {
            app = activeApp
        } else {
            guard let active = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier?.lowercased() == bundleId && $0.isActive
            }) else {
                return nil
            }
            app = active
        }

        guard app.isActive else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Try kAXFocusedWindowAttribute first - directly gets the focused window
        var focusedWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
           let focusedWindow = focusedWindowRef {
            let windowElement = focusedWindow as! AXUIElement

            // Check if window is minimized
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &minimized)
            if let isMinimized = minimized as? Bool, isMinimized {
                return nil
            }

            return windowElement
        }

        // Fall back to windows.first from kAXWindowsAttribute
        var windowList: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success else { return nil }

        guard let windows = windowList as? [AXUIElement], let firstWindow = windows.first else {
            return nil
        }

        // Check if window is minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(firstWindow, kAXMinimizedAttribute as CFString, &minimized)
        if let isMinimized = minimized as? Bool, isMinimized {
            return nil
        }

        return firstWindow
    }

    // MARK: - Window Frame Extraction

    private func getWindowFrame(_ windowElement: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef,
              let size = sizeRef else {
            return nil
        }

        var cgPoint = CGPoint.zero
        var cgSize = CGSize.zero

        AXValueGetValue(position as! AXValue, .cgPoint, &cgPoint)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)

        guard let primaryHeight = Self.primaryScreenHeight() else {
            return NSRect(origin: cgPoint, size: cgSize)
        }
        return Self.cocoaFrame(axOrigin: cgPoint, size: cgSize, primaryScreenHeight: primaryHeight)
    }

    /// Accessibility reports window positions in global coordinates whose origin is the
    /// **top**-left of the primary display (the one at (0, 0), with the menu bar);
    /// AppKit's origin is that display's **bottom**-left. The flip must use the primary
    /// display's height: `NSScreen.main` (the key window's screen) is wrong as soon as
    /// displays differ in height, and placed the sidebar too high on an external display.
    nonisolated static func cocoaFrame(axOrigin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: axOrigin.x, y: primaryScreenHeight - axOrigin.y - size.height, width: size.width, height: size.height)
    }

    /// Height of the primary display, the reference of both coordinate systems.
    private static func primaryScreenHeight() -> CGFloat? {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height
    }

    // MARK: - Position Calculation

    private func calculateSidebarFrame(browserFrame: NSRect, sidebarWidth: CGFloat) -> NSRect? {
        // Check minimum browser width requirement
        let minBrowserWidth: CGFloat = 600
        guard browserFrame.width >= minBrowserWidth else { return nil }

        // Detect which screen contains the browser window
        guard let screen = detectScreen(for: browserFrame) else { return nil }

        let screenFrame = screen.visibleFrame

        // Try preferred side first, then fall back to opposite side
        let preferredSide = sidebarPosition
        let oppositeSide: SidebarPosition = preferredSide == .left ? .right : .left

        if let x = sidebarX(for: preferredSide, browserFrame: browserFrame, sidebarWidth: sidebarWidth, screenFrame: screenFrame) {
            return NSRect(x: x, y: browserFrame.minY, width: sidebarWidth, height: browserFrame.height)
        }

        if let x = sidebarX(for: oppositeSide, browserFrame: browserFrame, sidebarWidth: sidebarWidth, screenFrame: screenFrame) {
            return NSRect(x: x, y: browserFrame.minY, width: sidebarWidth, height: browserFrame.height)
        }

        // Neither side has space
        return nil
    }

    /// Returns the X position for SidebArc on the given side, or nil if there isn't enough space.
    private func sidebarX(for side: SidebarPosition, browserFrame: NSRect, sidebarWidth: CGFloat, screenFrame: NSRect) -> CGFloat? {
        switch side {
        case .left:
            let x = browserFrame.minX - sidebarWidth
            return x >= screenFrame.minX ? x : nil
        case .right:
            let x = browserFrame.maxX
            return x + sidebarWidth <= screenFrame.maxX ? x : nil
        }
    }

    private func detectScreen(for frame: NSRect) -> NSScreen? {
        // Use cached screen if the frame is still within the same screen bounds
        if let cached = cachedScreen,
           let cachedBounds = cachedScreenFrame,
           cachedBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            return cached
        }

        // Recalculate if cache miss
        let screens = NSScreen.screens
        var bestScreen: NSScreen?
        var bestOverlap: CGFloat = 0

        for screen in screens {
            let intersection = frame.intersection(screen.frame)
            let overlap = intersection.width * intersection.height
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestScreen = screen
            }
        }

        let result = bestScreen ?? NSScreen.main
        cachedScreen = result
        cachedScreenFrame = result?.frame

        return result
    }

    // MARK: - Main Update Loop

    private func schedulePositionUpdate() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: positionDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateSidebarPosition()
            }
        }
    }

    private func updateSidebarPosition(forceShow: Bool = false) {
        guard isEnabled else { return }

        // Find the frontmost browser window
        guard let windowElement = findFrontmostBrowserWindow() else {
            hide("position update: no frontmost browser window")
            return
        }

        // Get the browser window frame
        guard let browserFrame = getWindowFrame(windowElement) else {
            hide("position update: no browser window frame")
            return
        }

        // Check if frame has changed
        let frameChanged = lastBrowserFrame != browserFrame
        lastBrowserFrame = browserFrame

        // The user's width (they may have resized the attached sidebar)
        let sidebarWidth = delegate?.attachmentServiceSidebarWidth(self) ?? ThemeConstants.Sizing.attachedSidebarDefaultWidth

        // Calculate new SidebArc frame
        guard let newFrame = calculateSidebarFrame(browserFrame: browserFrame, sidebarWidth: sidebarWidth) else {
            // Invalid frame (browser too narrow, not enough space, etc.)
            hide("position update: no room beside the browser window")
            return
        }

        // Check if calculated frame has changed
        let calculatedFrameChanged = lastSidebarFrame != newFrame
        lastSidebarFrame = newFrame

        // Only update if frame changed or if we're forcing show (e.g., app switch)
        if forceShow {
            logger.notice("Show beside \(self.attachedBundleId ?? "?", privacy: .public) pid \(self.browserApp?.processIdentifier ?? 0)")
        }
        if frameChanged || calculatedFrameChanged || forceShow {
            // Notify delegate to position window with smooth animation
            delegate?.attachmentService(self, shouldPositionWindow: newFrame, animated: true)
        }
    }

    // MARK: - Browser Attachment

    /// Attaches to the frontmost app if it is a browser in the set, switching from
    /// the previously followed browser when it is a different one.
    private func attachToBrowser() {
        cancelWindowRetry()
        guard !browserBundleIds.isEmpty else {
            logger.notice("No browsers configured")
            return
        }

        guard let frontmost = BrowserManager.frontmostApp() else {
            hide("no frontmost app")
            return
        }

        // SidebArc itself in front (Settings: attachment, position or browsers just
        // changed): leave the sidebar alone; the next app activation decides.
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        guard isAttachable(frontmost.bundleIdentifier), let frontmostId = frontmost.bundleIdentifier?.lowercased() else {
            hide("frontmost \(frontmost.bundleIdentifier ?? "?") (pid \(frontmost.processIdentifier)) is not a browser of the set")
            return
        }

        let sameBrowserPids = frontmost.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        } ?? []
        if Self.isTransientInstance(pid: frontmost.processIdentifier,
                                    finishedLaunching: frontmost.isFinishedLaunching,
                                    sameBrowserPids: sameBrowserPids) {
            // Leave the sidebar and the observers as they are.
            logger.notice("Ignored \(frontmostId, privacy: .public) pid \(frontmost.processIdentifier): short-lived instance opening a link")
            return
        }

        if attachedBundleId != frontmostId {
            // Another browser of the set: drop the old one's observers first.
            detachFromBrowser()
            attachedBundleId = frontmostId
        }

        // Setup app-level observer to detect window focus changes within the browser
        observeAppWindowChanges(app: frontmost)

        // Find browser window
        guard let windowElement = findFrontmostBrowserWindow(activeApp: frontmost) else {
            hide("no window found for \(frontmost.bundleIdentifier ?? "?") pid \(frontmost.processIdentifier) (active \(frontmost.isActive), launched \(frontmost.isFinishedLaunching))")
            waitForFirstWindow(of: frontmost)
            return
        }

        // Check if we're already observing this exact window
        if let existingElement = browserWindowElement,
           CFEqual(existingElement, windowElement) {
            // Re-register window observers if they were cleaned up
            if observers.isEmpty {
                browserApp = frontmost
                observeBrowserWindow()
            }
            updateSidebarPosition(forceShow: true)
            return
        }

        logger.debug("New browser window, observing it")

        // Different window - cleanup old window observers and setup new ones
        cleanupObservers()
        browserWindowElement = windowElement
        browserApp = frontmost

        // Setup observers for this window
        observeBrowserWindow()

        // Perform initial position update and show window
        updateSidebarPosition(forceShow: true)
    }

    // MARK: - AX Observers

    private func observeBrowserWindow() {
        guard let windowElement = browserWindowElement,
              let app = browserApp else { return }

        var observer: AXObserver?
        let error = AXObserverCreate(app.processIdentifier, { (_, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let service = Unmanaged<WindowAttachmentService>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                let notificationName = notification as String

                if notificationName == (kAXMovedNotification as String) || notificationName == (kAXResizedNotification as String) {
                    service.schedulePositionUpdate()
                } else if notificationName == (kAXUIElementDestroyedNotification as String) {
                    service.hide("browser window closed")
                    service.cleanupObservers()
                }
            }
        }, &observer)

        guard error == .success, let observer = observer else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register for notifications
        AXObserverAddNotification(observer, windowElement, kAXMovedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, windowElement, kAXResizedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, windowElement, kAXUIElementDestroyedNotification as CFString, selfPtr)

        // Add observer to run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        observers.append(observer)
    }

    private func observeAppWindowChanges(app: NSRunningApplication) {
        let newPid = app.processIdentifier

        // If observer exists for a different PID, clean it up first
        if appObserver != nil && appObserverPid != newPid {
            cleanupAppObserver()
        }

        guard appObserver == nil else { return }

        var observer: AXObserver?
        let error = AXObserverCreate(app.processIdentifier, { (_, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let service = Unmanaged<WindowAttachmentService>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                // User switched to a different window within the same browser app
                service.attachToBrowser()
            }
        }, &observer)

        guard error == .success, let observer = observer else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        let added = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        if added != .success {
            logger.notice("Window-focus observer for pid \(newPid) not added (AXError \(added.rawValue)); waiting for a window instead")
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.appObserver = observer
        self.appObserverPid = newPid
    }

    private func cleanupAppObserver() {
        if let observer = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            appObserver = nil
            appObserverPid = nil
        }
    }

    private func cleanupObservers() {
        for observer in observers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        lastBrowserFrame = nil
        lastSidebarFrame = nil
        cachedScreen = nil
        cachedScreenFrame = nil
        isAnimating = false
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let activatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let bundleId = app.bundleIdentifier
                let ownBundleId = Bundle.main.bundleIdentifier

                switch Self.activationDecision(
                    activated: bundleId,
                    previous: self.lastFrontmostBundleId,
                    ownBundleId: ownBundleId,
                    browsers: self.browserBundleIds
                ) {
                case .attach:
                    self.logger.notice("Activated \(bundleId ?? "?", privacy: .public) pid \(app.processIdentifier): attach")
                    self.lastFrontmostBundleId = bundleId
                    self.attachToBrowser()
                case .keepVisible:
                    // Clicking between the browser and the sidebar.
                    self.logger.notice("Activated SidebArc after a browser: keep visible")
                case .hide:
                    if bundleId != ownBundleId {
                        self.lastFrontmostBundleId = bundleId
                    }
                    self.cancelWindowRetry()
                    self.hide("activated \(bundleId ?? "?") pid \(app.processIdentifier), not a browser of the set")
                }
            }
        }

        let terminatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let attached = self.attachedBundleId, app.bundleIdentifier?.lowercased() == attached {
                    // Skip cleanup if the browser is still running: the terminated
                    // process is likely a short-lived instance opened for a browser
                    // profile.
                    guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier?.lowercased() == attached }) else {
                        return
                    }
                    // Followed browser quit - hide and clean up
                    self.hide("followed browser \(attached) quit")
                    self.detachFromBrowser()
                }
            }
        }

        // A browser that launches is attached when it activates (above).
        workspaceObservers = [activatedObserver, terminatedObserver]
    }

    private func cleanupWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Screen Change Observer

    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Use longer debounce for screen changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateSidebarPosition()
            }
        }
    }

    private func cleanupScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }
}

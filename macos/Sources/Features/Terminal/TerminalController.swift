import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController
{
    override var windowNibName: NSNib.Name? { "Terminal" }

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: Ghostty.SplitNode? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: Ghostty.SplitNode?, to: Ghostty.SplitNode?) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is now nil then we close our window.
        if (to == nil) {
            self.window?.close()
        }
    }

    //MARK: - Methods

    func configDidReload() {
        guard let window = window as? TerminalWindow else { return }
        window.focusFollowsMouse = ghostty.config.focusFollowsMouse
        syncAppearance()
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // Reset this to false. It'll be set back to true later.
        tabListenForFrame = false

        guard let windows = self.window?.tabbedWindows as? [TerminalWindow] else { return }

        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = windows.count > 1

        for (tab, window) in zip(1..., windows) {
            // We need to clear any windows beyond this because they have had
            // a keyEquivalent set previously.
            guard tab <= 9 else {
                window.keyEquivalent = ""
                continue
            }

            let action = "goto_tab:\(tab)"
            if let equiv = ghostty.config.keyEquivalent(for: action) {
                window.keyEquivalent = "\(equiv)"
            } else {
                window.keyEquivalent = ""
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    private func syncAppearance() {
        guard let window = self.window as? TerminalWindow else { return }

        // If our window is not visible, then delay this. This is possible specifically
        // during state restoration but probably in other scenarios as well. To delay,
        // we just loop directly on the dispatch queue. We have to delay because some
        // APIs such as window blur have no effect unless the window is visible.
        guard window.isVisible else {
            // Weak window so that if the window changes or is destroyed we aren't holding a ref
            DispatchQueue.main.async { [weak self] in self?.syncAppearance() }
            return
        }

        // Set the font for the window and tab titles.
        if let titleFontName = ghostty.config.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // If we have window transparency then set it transparent. Otherwise set it opaque.
        if (ghostty.config.backgroundOpacity < 1) {
            window.isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            ghostty_set_window_background_blur(ghostty.app, Unmanaged.passUnretained(window).toOpaque())
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }

        window.hasShadow = ghostty.config.macosWindowShadow

        guard window.hasStyledTabs else { return }

        // The titlebar is always updated. We don't need to worry about opacity
        // because we handle it here.
        let backgroundColor = OSColor(ghostty.config.backgroundColor)
        window.titlebarColor = backgroundColor.withAlphaComponent(ghostty.config.backgroundOpacity)

        if (window.isOpaque) {
            // Bg color is only synced if we have no transparency. This is because
            // the transparency is handled at the surface level (window.backgroundColor
            // ignores alpha components)
            window.backgroundColor = backgroundColor

            // If there is transparency, calling this will make the titlebar opaque
            // so we only call this if we are opaque.
            window.updateTabBar()
        }
    }

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        let newStyle = mode.style(for: window)
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = nil
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then unset the style so that we replace it next time.
                oldStyle.exit()
                self.fullscreenStyle = nil

                // Fix our focus
                if let focusedSurface {
                    Ghostty.moveFocus(to: focusedSurface)
                }

                // We're done
                return
            }

            // Style is the same.
        } else {
            // No old style, so set to our new style.
            self.fullscreenStyle = newStyle
        }

        guard let fullscreenStyle else { return }
        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }

        // For some reason focus can get lost when we change fullscreen. Regardless of
        // mode above we just move it back.
        if let focusedSurface {
            Ghostty.moveFocus(to: focusedSurface)
        }
    }

    //MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        guard let window = window as? TerminalWindow else { return }

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if (restorable) {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If window decorations are disabled, remove our title
        if (!ghostty.config.windowDecorations) { window.styleMask.remove(.titled) }

        // Terminals typically operate in sRGB color space and macOS defaults
        // to "native" which is typically P3. There is a lot more resources
        // covered in this GitHub issue: https://github.com/mitchellh/ghostty/pull/376
        // Ghostty defaults to sRGB but this can be overridden.
        switch (ghostty.config.windowColorspace) {
        case "display-p3":
            window.colorSpace = .displayP3
        case "srgb":
            fallthrough
        default:
            window.colorSpace = .sRGB
        }

        // If we have only a single surface (no splits) and that surface requested
        // an initial size then we set it here now.
        if case let .leaf(leaf) = surfaceTree {
            if let initialSize = leaf.surface.initialSize,
               let screen = window.screen ?? NSScreen.main {
                // Setup our frame. We need to first subtract the views frame so that we can
                // just get the chrome frame so that we only affect the surface view size.
                var frame = window.frame
                frame.size.width -= leaf.surface.frame.size.width
                frame.size.height -= leaf.surface.frame.size.height
                frame.size.width += min(initialSize.width, screen.frame.width)
                frame.size.height += min(initialSize.height, screen.frame.height)

                // We have no tabs and we are not a split, so set the initial size of the window.
                window.setFrame(frame, display: true)
            }
        }

        // Center the window to start, we'll move the window frame automatically
        // when cascading.
        window.center()

        // Make sure our theme is set on the window so styling is correct.
        if let windowTheme = ghostty.config.windowTheme {
            window.windowTheme = .init(rawValue: windowTheme)
        }

        // Handle titlebar tabs config option. Something about what we do while setting up the
        // titlebar tabs interferes with the window restore process unless window.tabbingMode
        // is set to .preferred, so we set it, and switch back to automatic as soon as we can.
        if (ghostty.config.macosTitlebarStyle == "tabs") {
            window.tabbingMode = .preferred
            window.titlebarTabs = true
            DispatchQueue.main.async {
                window.tabbingMode = .automatic
            }
        } else if (ghostty.config.macosTitlebarStyle == "transparent") {
            window.transparentTabs = true
        }

        if window.hasStyledTabs {
            // Set the background color of the window
            let backgroundColor = NSColor(ghostty.config.backgroundColor)
            window.backgroundColor = backgroundColor

            // This makes sure our titlebar renders correctly when there is a transparent background
            window.titlebarColor = backgroundColor.withAlphaComponent(ghostty.config.backgroundOpacity)
        }

        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))

        // If our titlebar style is "hidden" we adjust the style appropriately
        if (ghostty.config.macosTitlebarStyle == "hidden") {
            window.styleMask = [
                // We need `titled` in the mask to get the normal window frame
                .titled,

                // Full size content view so we can extend
                // content in to the hidden titlebar's area
                .fullSizeContentView,

                .resizable,
                .closable,
                .miniaturizable,
            ]

            // Hide the title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            // Hide the traffic lights (window control buttons)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Disallow tabbing if the titlebar is hidden, since that will (should) also hide the tab bar.
            window.tabbingMode = .disallowed
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        if (!window.styleMask.contains(.fullScreen)) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        window.focusFollowsMouse = ghostty.config.focusFollowsMouse

        // Apply any additional appearance-related properties to the new window.
        syncAppearance()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    //MARK: - NSWindowDelegate

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        self.relabelTabs()
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
    }

    func windowDidMove(_ notification: Notification) {
        self.fixTabBar()
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction override func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else {
            // No tabs, no tab group, just perform a normal close.
            window.performClose(sender)
            return
        }

        // If have one window then we just do a normal close
        if tabGroup.windows.count == 1 {
            window.performClose(sender)
            return
        }

        // Check if any windows require close confirmation.
        var needsConfirm: Bool = false
        for tabWindow in tabGroup.windows {
            guard let c = tabWindow.windowController as? TerminalController else { continue }
            if (c.surfaceTree?.needsConfirmQuit() ?? false) {
                needsConfirm = true
                break
            }
        }

        // If none need confirmation then we can just close all the windows.
        if (!needsConfirm) {
            for tabWindow in tabGroup.windows {
                tabWindow.close()
            }

            return
        }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "All terminal sessions in this window will be terminated."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: { response in
            if (response == .alertFirstButtonReturn) {
                for tabWindow in tabGroup.windows {
                    tabWindow.close()
                }
            }
        })
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    //MARK: - TerminalViewDelegate

    override func titleDidChange(to: String) {
        super.titleDidChange(to: to)

        guard let window = window as? TerminalWindow else { return }

        // Custom toolbar-based title used when titlebar tabs are enabled.
        if let toolbar = window.toolbar as? TerminalToolbar {
            if (window.titlebarTabs || ghostty.config.macosTitlebarStyle == "hidden") {
                // Updating the title text as above automatically reveals the
                // native title view in macOS 15.0 and above. Since we're using
                // a custom view instead, we need to re-hide it.
                window.titleVisibility = .hidden
            }
            toolbar.titleText = to
        }
    }

    override func surfaceTreeDidChange() {
        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
    }

    override func zoomStateDidChange(to: Bool) {
        guard let window = window as? TerminalWindow else { return }
        window.surfaceIsZoomed = to
    }

    //MARK: - Notifications

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if (tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue) {
                if (selectedIndex == 0) {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue) {
                if (selectedIndex == tabbedWindows.count - 1) {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue) {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // Tabs are 0-indexed here, so we subtract one from the key the user hit.
            finalIndex = Int(tabIndex - 1)
        }

        guard finalIndex >= 0 && finalIndex < tabbedWindows.count else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }


    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }
}

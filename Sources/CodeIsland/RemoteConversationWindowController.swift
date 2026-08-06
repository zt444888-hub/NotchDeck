import AppKit
import SwiftUI

/// Hosts the Mac-side Remote AI conversation panel (the visible "agent
/// window" on the desktop, mirroring the phone's conversations via CloudKit).
@MainActor
final class RemoteConversationWindowController {
    static let shared = RemoteConversationWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        // Switch to regular activation policy so the window can receive focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panelView = RemoteConversationPanelView()
        let hostingView = NSHostingView(rootView: panelView)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(720, screenW * 0.5)
        let winH = min(520, screenH * 0.6)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["remote_conversation"]
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.window = window
    }

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
    }
}

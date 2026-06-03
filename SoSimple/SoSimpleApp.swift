//
//  SoSimpleApp.swift
//  SoSimple
//
//  Created by thameemh on 2-6-26.
//

import SwiftUI
import AppKit

@main
struct SoSimpleApp: App {
    @StateObject private var store = OutlineStore()
    @State private var tabController = NativeTabController()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(store: store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    tabController.openTab(store: store)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Toggle Split View") {
                    NotificationCenter.default.post(name: .toggleWorkspaceSplitView, object: nil)
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])

                Button("Toggle Tasks Sidebar") {
                    NotificationCenter.default.post(name: .toggleWorkspaceTaskSidebar, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class NativeTabController: NSObject, NSWindowDelegate {
    private var retainedWindows: [NSWindow] = []

    func openTab(store: OutlineStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        configure(window)
        window.contentViewController = NSHostingController(rootView: WorkspaceView(store: store))
        window.delegate = self
        retainedWindows.append(window)

        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            configure(activeWindow)
            activeWindow.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        retainedWindows.removeAll { $0 === closedWindow }
    }

    private func configure(_ window: NSWindow) {
        window.title = "SoSimple"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "SoSimpleOutlineWindow"
    }
}

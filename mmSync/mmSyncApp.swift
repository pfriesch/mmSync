//
//  mmSyncApp.swift
//  mmSync
//
//  Created by Pius Friesch on 29.05.25.
//

import SwiftUI
import SwiftData
import AppKit

@main
struct mmSyncApp: App {
    @StateObject private var moneyMoneyManager: MoneyMoneyManager = MoneyMoneyManager()
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarButtonsView()
                .environmentObject(moneyMoneyManager)
        } label: {
            MenuBarIconView(manager: moneyMoneyManager)
        }
        .environmentObject(moneyMoneyManager)
    }
}

/// SwiftUI's `Settings` scene and `SettingsLink` don't reliably open from a menu-bar-only app,
/// so the settings window is managed directly.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(manager: MoneyMoneyManager) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environmentObject(manager)
            ))
            window.title = "mmSync Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarIconView: View {
    @ObservedObject var manager: MoneyMoneyManager
    
    var body: some View {
        Image(systemName: manager.syncStatusIcon)
            .foregroundColor(manager.syncStatusColor)
            .symbolEffect(.bounce, options: .repeating, value: manager.isSyncing)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }
}

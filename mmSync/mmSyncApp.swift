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
        
        Settings {
            SettingsView()
                .environmentObject(moneyMoneyManager)
        }
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

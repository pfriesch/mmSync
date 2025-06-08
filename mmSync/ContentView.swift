//
//  ContentView.swift
//  mmSync
//
//  Created by Pius Friesch on 29.05.25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var manager: MoneyMoneyManager
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        VStack {
            if !manager.isICloudAvailable {
                ContentUnavailableView {
                    Label("iCloud Not Available", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Please sign in to iCloud to use mmSync.")
                } actions: {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("mmSync is Running", systemImage: "checkmark.circle")
                } description: {
                    Text("The app is running in the menu bar.")
                } actions: {
                    Button("Open Menu Bar") {
                        if let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength).button {
                            statusItem.performClick(nil)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 200)
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MoneyMoneyManager())
}

import SwiftUI
import AppKit

struct MenuBarButtonsView: View {
    @EnvironmentObject private var manager: MoneyMoneyManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status section
            Group {
                Text("Status")
                    .font(.headline)
                
                HStack {
                    Image(systemName: manager.syncStatusIcon)
                        .foregroundColor(manager.syncStatusColor)
                    Text(manager.syncStatusText)
                }
                
                if let lastSync = manager.lastSyncTime {
                    Text("Last sync: \(lastSync.formatted())")
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            // Actions section
            Group {
                Button(action: {
                    Task {
                        await manager.startSync()
                    }
                }) {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(manager.isSyncing)
                
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit", systemImage: "power")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .frame(width: 200)
    }
}

#Preview {
    MenuBarButtonsView()
        .environmentObject(MoneyMoneyManager())
} 
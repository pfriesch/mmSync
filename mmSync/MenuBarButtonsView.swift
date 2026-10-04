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

                if manager.hasConflict {
                    Button {
                        Task { await manager.useICloudVersion() }
                    } label: {
                        Label("Use iCloud Version", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(manager.isSyncing)

                    Button {
                        Task { await manager.useThisMacsVersion() }
                    } label: {
                        Label("Use This Mac's Version", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(manager.isSyncing)
                }

                if manager.needsFullDiskAccess {
                    Button {
                        manager.openFullDiskAccessSettings()
                    } label: {
                        Label("Grant Full Disk Access…", systemImage: "lock.open")
                    }
                }

                Button {
                    manager.showBackupsInFinder()
                } label: {
                    Label("Show Backups", systemImage: "folder")
                }

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
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: MoneyMoneyManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // General Settings
            Form {
                Section("iCloud Status") {
                    HStack {
                        Image(systemName: manager.isICloudAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(manager.isICloudAvailable ? .green : .red)
                        Text(manager.isICloudAvailable ? "iCloud is available" : "iCloud is not available")
                    }
                }
                
                Section("Sync Status") {
                    HStack {
                        Image(systemName: manager.syncStatus.icon)
                            .foregroundColor(manager.syncStatus.color)
                        Text(manager.syncStatusText)
                    }
                    
                    if let lastSync = manager.lastSyncTime {
                        Text("Last sync: \(lastSync.formatted())")
                    }
                }
                
                Section {
                    Button("Sync Now") {
                        Task {
                            await manager.startSync()
                        }
                    }
                    .disabled(manager.isSyncing)
                }
            }
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .tag(0)
            
            // Logs
            LogsView(logs: manager.logs)
                .tabItem {
                    Label("Logs", systemImage: "list.bullet")
                }
                .tag(1)
        }
        .frame(width: 500, height: 400)
    }
}

struct LogsView: View {
    let logs: [LogEntry]
    
    var body: some View {
        List(logs) { entry in
            HStack {
                Text(entry.timestamp.formatted())
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(entry.level.rawValue)
                    .font(.caption)
                    .foregroundColor(entry.level.color)
                    .frame(width: 60, alignment: .leading)
                
                Text(entry.message)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MoneyMoneyManager())
} 
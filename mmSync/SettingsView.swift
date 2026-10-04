import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: MoneyMoneyManager
    @State private var selectedTab = 0
    @State private var isPickingFolder = false
    @State private var folderError: String?
    
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
                
                Section("Background") {
                    Toggle("Open at Login", isOn: Binding(
                        get: { manager.loginItemStatus == .enabled || manager.loginItemStatus == .requiresApproval },
                        set: { manager.setOpensAtLogin($0) }
                    ))
                    Text("mmSync starts when you log in and syncs whenever MoneyMoney quits.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if manager.loginItemStatus == .requiresApproval {
                        Text("macOS needs your approval to open mmSync at login.")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Button("Open Login Items Settings…") { manager.openLoginItemsSettings() }
                    }
                }
                .onAppear { manager.refreshLoginItemStatus() }

                Section("MoneyMoney Data") {
                    let url = Config.moneyMoneyDataURL
                    let found = Config.isMoneyMoneyDataDirectory(url)
                    HStack {
                        Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(found ? .green : .red)
                        Text(found ? "Database found" : "Database not found (or no Full Disk Access)")
                    }
                    Text(url.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    if let folderError {
                        Text(folderError).font(.caption).foregroundColor(.red)
                    }
                    HStack {
                        Button("Choose Folder…") { isPickingFolder = true }
                        if url != Config.defaultMoneyMoneyDataURL {
                            Button("Use Default") {
                                folderError = nil
                                manager.setMoneyMoneyDataURL(nil)
                            }
                        }
                    }
                    .disabled(manager.isSyncing)
                }
                .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    if Config.isMoneyMoneyDataDirectory(url) {
                        folderError = nil
                        manager.setMoneyMoneyDataURL(url)
                    } else {
                        folderError = "No Database/MoneyMoney.sqlite in \(url.lastPathComponent)"
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
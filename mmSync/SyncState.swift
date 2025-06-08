import Foundation
import SwiftData

@Model
final class SyncState {
    var computerName: String
    var lastKnownState: String
    var lastSyncedFolder: String
    var lastSyncStatus: String
    var lastSyncTime: Date
    var totalSyncs: Int
    var lastError: String?
    var lastSuccessfulSync: Date?
    var lastBackupURL: String
    
    init(
        computerName: String = Host.current().localizedName ?? "Unknown",
        lastKnownState: String = "",
        lastSyncedFolder: String = "",
        lastSyncStatus: String = "idle",
        lastSyncTime: Date = .distantPast,
        totalSyncs: Int = 0,
        lastBackupURL: String
    ) {
        self.computerName = computerName
        self.lastKnownState = lastKnownState
        self.lastSyncedFolder = lastSyncedFolder
        self.lastSyncStatus = lastSyncStatus
        self.lastSyncTime = lastSyncTime
        self.totalSyncs = totalSyncs
        self.lastBackupURL = lastBackupURL
    }
} 
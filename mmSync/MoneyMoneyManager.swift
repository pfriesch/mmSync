import Foundation
import SwiftData
import OSLog
import AppKit
import UserNotifications
import CloudKit
import SwiftUI

public enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    
    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
}

public enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(String)
    case error(String)
    
    var icon: String {
        switch self {
        case .idle:
            return "arrow.triangle.2.circlepath"
        case .syncing:
            return "arrow.triangle.2.circlepath.circle"
        case .success:
            return "checkmark.circle"
        case .error:
            return "exclamationmark.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .idle: return .primary
        case .syncing: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

public enum SyncError: LocalizedError {
    case moneyMoneyRunning
    case lockFileExists
    case sourceDirectoryNotFound
    case destinationDirectoryNotFound
    case securityScopeError(Error)
    case fileOperationError(Error)
    case invalidDirectoryStructure
    case iCloudNotAvailable
    case conflictDetected
    case noBackupFound
    case staleLockFile
    
    public var errorDescription: String? {
        switch self {
        case .moneyMoneyRunning:
            return "MoneyMoney is currently running. Please close it before syncing."
        case .lockFileExists:
            return "Another sync operation is in progress."
        case .sourceDirectoryNotFound:
            return "Source directory not found."
        case .destinationDirectoryNotFound:
            return "Destination directory not found."
        case .securityScopeError(let error):
            return "Failed to access required directories: \(error.localizedDescription)"
        case .fileOperationError(let error):
            return "File operation failed: \(error.localizedDescription)"
        case .invalidDirectoryStructure:
            return "Invalid directory structure in MoneyMoney directory."
        case .iCloudNotAvailable:
            return "iCloud is not available. Please sign in to iCloud to use mmSync."
        case .conflictDetected:
            return "A conflict was detected between local and iCloud data. Please resolve manually."
        case .noBackupFound:
            return "No backup found to sync from or to iCloud."
        case .staleLockFile:
            return "Lock file is stale. Please check if MoneyMoney is running properly."
        }
    }
}

@MainActor
public class MoneyMoneyManager: ObservableObject {
    private let logger = Logger(subsystem: "com.piofresco.mmsync", category: "MoneyMoneyManager")
    private let fileManager = FileManager.default
    private let maxBackups = 3
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let iCloudBackupURL: URL
    private let moneyMoneyURL: URL
    
    @Published public private(set) var syncStatus: SyncStatus = .idle
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncTime: Date?
    @Published public private(set) var isICloudAvailable = false
    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 1000
    
    private let staleLockTimeout: TimeInterval = 4 * 60 * 60 // 4 hours
    private var lockFileMonitor: Timer?
    
    var syncStatusIcon: String {
        syncStatus.icon
    }
    
    var syncStatusColor: Color {
        syncStatus.color
    }
    
    var syncStatusText: String {
        switch syncStatus {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing..."
        case .success(let message):
            return "Success: \(message)"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    public init() {
        // Initialize SwiftData
        let schema = Schema([SyncState.self])
        let modelConfiguration = ModelConfiguration(schema: schema)
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            logger.error("Failed to initialize SwiftData: \(error.localizedDescription)")
            modelContainer = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        
        // Initialize URLs
        let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Backups/MoneyMoney")
        self.iCloudBackupURL = iCloudURL ?? URL(fileURLWithPath: Config.iCloudBackupPath)
        
        let homeURL = fileManager.homeDirectoryForCurrentUser
        self.moneyMoneyURL = homeURL.appendingPathComponent("Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support")
        
        // Initialize model context
        self.modelContext = modelContainer.mainContext
        
        setupNotifications()
        
        Task {
            await checkICloudAvailability()
            await startMonitoring()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task {
                await self?.checkICloudAvailability()
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let bundleIdentifier = notification.userInfo?["NSApplicationBundleIdentifier"] as? String,
               bundleIdentifier == "com.moneymoney-app.retail" {
                Task {
                    await self?.handleMoneyMoneyLaunch()
                }
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let bundleIdentifier = notification.userInfo?["NSApplicationBundleIdentifier"] as? String,
               bundleIdentifier == "com.moneymoney-app.retail" {
                Task {
                    await self?.handleMoneyMoneyTermination()
                }
            }
        }
    }
    
    private func addLog(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogEntries {
                self.logs.removeLast()
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        
        addLog("\(title): \(body)", level: title.contains("Error") ? .error : .info)
    }
    
    public func checkICloudAvailability() async {
        let fileManager = FileManager.default
        let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Backups/MoneyMoney")
        
        DispatchQueue.main.async {
            if let iCloudURL = iCloudURL {
                do {
                    try fileManager.createDirectory(at: iCloudURL, withIntermediateDirectories: true)
                    self.isICloudAvailable = true
                } catch {
                    self.logger.error("Failed to create iCloud directory: \(error.localizedDescription)")
                    self.isICloudAvailable = false
                    self.sendNotification(
                        title: "iCloud Error",
                        body: "Failed to access iCloud. Please check your iCloud settings."
                    )
                }
            } else {
                self.isICloudAvailable = false
                self.sendNotification(
                    title: "iCloud Error",
                    body: "iCloud is not available. Please sign in to iCloud to use mmSync."
                )
            }
        }
    }
    
    private func handleMoneyMoneyLaunch() async {
        // Create lock file when MoneyMoney launches
        let lockFileURL = createLockFileURL()
        do {
            try "".write(to: lockFileURL, atomically: true, encoding: .utf8)
            addLog("Created lock file for MoneyMoney launch", level: .info)
        } catch {
            addLog("Failed to create lock file: \(error.localizedDescription)", level: .error)
        }
    }
    
    private func handleMoneyMoneyTermination() async {
        // Remove lock file and start sync when MoneyMoney terminates
        let lockFileURL = createLockFileURL()
        do {
            try fileManager.removeItem(at: lockFileURL)
            addLog("Removed lock file after MoneyMoney termination", level: .info)
            await startSync()
        } catch {
            addLog("Failed to remove lock file: \(error.localizedDescription)", level: .error)
        }
    }
    
    private func createLockFileURL() -> URL {
        let computerName = Host.current().localizedName ?? "Unknown"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = dateFormatter.string(from: Date())
        return iCloudBackupURL.appendingPathComponent("\(timestamp)_\(computerName).mmSyncLockFile")
    }
    
    private func createBackupURL() -> URL {
        let computerName = Host.current().localizedName ?? "Unknown"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = dateFormatter.string(from: Date())
        return iCloudBackupURL.appendingPathComponent("\(timestamp)_\(computerName)")
    }
    
    public func startSync() async {
        guard !isSyncing else { return }
        
        isSyncing = true
        syncStatus = .syncing
        addLog("Starting sync process", level: .info)
        
        do {
            try await performSync()
            syncStatus = .success("Sync completed successfully")
            lastSyncTime = Date()
            addLog("Sync completed successfully", level: .info)
            sendNotification(title: "Sync Complete", body: "Your MoneyMoney data has been synced successfully.")
        } catch {
            let errorMessage = error.localizedDescription
            syncStatus = .error(errorMessage)
            addLog("Sync failed: \(errorMessage)", level: .error)
            sendNotification(title: "Sync Error", body: errorMessage)
        }
        
        isSyncing = false
    }
    
    private func performSync() async throws {
        // Check if MoneyMoney is running
        if isMoneyMoneyRunning() {
            throw SyncError.moneyMoneyRunning
        }
        
        // Check for lock file
        let lockFileURL = createLockFileURL()
        if fileManager.fileExists(atPath: lockFileURL.path) {
            // Check if lock file is stale
            if let attributes = try? fileManager.attributesOfItem(atPath: lockFileURL.path),
               let creationDate = attributes[.creationDate] as? Date,
               Date().timeIntervalSince(creationDate) > staleLockTimeout {
                throw SyncError.staleLockFile
            }
            throw SyncError.lockFileExists
        }
        
        // Check iCloud availability
        guard isICloudAvailable else {
            throw SyncError.iCloudNotAvailable
        }
        
        // Perform sync
        let backupURL = createBackupURL()
        try await syncToICloud(backupURL: backupURL)
        
        // Clean up old backups
        try await cleanupOldBackups()
    }
    
    private func syncToICloud(backupURL: URL) async throws {
        // Create backup directory
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
        
        // Copy MoneyMoney data to backup
        try fileManager.copyItem(at: moneyMoneyURL, to: backupURL.appendingPathComponent("MoneyMoney"))
        
        // Update sync state
        let syncState = SyncState(lastSyncTime: Date(), lastBackupURL: backupURL.path)
        modelContext.insert(syncState)
        try modelContext.save()
    }
    
    private func cleanupOldBackups() async throws {
        let backupURLs = try fileManager.contentsOfDirectory(at: iCloudBackupURL, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension != "mmSyncLockFile" }
            .sorted { url1, url2 in
                let date1 = try fileManager.attributesOfItem(atPath: url1.path)[.creationDate] as? Date ?? Date.distantPast
                let date2 = try fileManager.attributesOfItem(atPath: url2.path)[.creationDate] as? Date ?? Date.distantPast
                return date1 > date2
            }
        
        // Keep only the last 3 backups per computer
        let computerName = Host.current().localizedName ?? "Unknown"
        let computerBackups = backupURLs.filter { $0.lastPathComponent.contains(computerName) }
        
        if computerBackups.count > maxBackups {
            for backupURL in computerBackups[maxBackups...] {
                try fileManager.removeItem(at: backupURL)
                addLog("Removed old backup: \(backupURL.lastPathComponent)", level: .info)
            }
        }
    }
    
    private func isMoneyMoneyRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == "com.moneymoney-app.retail" }
    }
    
    private func startMonitoring() async {
        // Start monitoring iCloud backup folder for changes
        let backupFolderURL = iCloudBackupURL
        
        do {
            let resourceValues = try backupFolderURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modificationDate = resourceValues.contentModificationDate {
                addLog("Last backup folder modification: \(modificationDate)", level: .debug)
            }
        } catch {
            addLog("Failed to get backup folder modification date: \(error.localizedDescription)", level: .error)
        }
    }
} 

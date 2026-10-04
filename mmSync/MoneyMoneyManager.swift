import Foundation
import OSLog
import AppKit
import UserNotifications
import SwiftUI
import ServiceManagement

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
    case iCloudNotAvailable
    case iCloudNotReady
    case conflictDetected
    case noBackupFound
    case noAccess
    case lockedBy(String, Date)

    public var errorDescription: String? {
        switch self {
        case .moneyMoneyRunning:
            return "MoneyMoney is currently running. Please close it before syncing."
        case .iCloudNotAvailable:
            return "iCloud Drive is not available. Please sign in to iCloud to use mmSync."
        case .iCloudNotReady:
            return "iCloud is still downloading the latest database. Will retry."
        case .conflictDetected:
            return "This Mac and iCloud both have changes. Choose which version to keep."
        case .noBackupFound:
            return "No database found in iCloud."
        case .noAccess:
            return "mmSync can't read MoneyMoney's data. Grant Full Disk Access in System Settings."
        case .lockedBy(let mac, let date):
            return "MoneyMoney is open on \(mac) (since \(date.formatted(date: .abbreviated, time: .shortened)))."
        }
    }
}

@MainActor
public class MoneyMoneyManager: ObservableObject {
    private let logger = Logger(subsystem: "com.piofresco.mmsync", category: "MoneyMoneyManager")
    private var engine: SyncEngine
    private var pollTimer: Timer?

    @Published public private(set) var syncStatus: SyncStatus = .idle
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncTime: Date?
    @Published public private(set) var isICloudAvailable = false
    @Published public private(set) var hasConflict = false
    @Published public private(set) var needsFullDiskAccess = false
    @Published public private(set) var loginItemStatus = SMAppService.mainApp.status
    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 1000

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
            return message
        case .error(let message):
            return "Error: \(message)"
        }
    }

    public init() {
        engine = Self.makeEngine()
        lastSyncTime = engine.lastSynced()?.date

        // Unit tests run inside this app; never touch real data from them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        setupNotifications()

        // Start at login (launchd-managed) so syncs happen without opening mmSync by hand.
        if !UserDefaults.standard.bool(forKey: Config.didSetUpLoginItemKey) {
            UserDefaults.standard.set(true, forKey: Config.didSetUpLoginItemKey)
            setOpensAtLogin(true)
        }

        // devmode: polls iCloud for other Macs' pushes; switch to NSMetadataQuery if 5 min latency hurts
        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.syncIfMoneyMoneyClosed() }
        }

        Task { await syncIfMoneyMoneyClosed() }
    }

    private func setupNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task {
                await self?.syncIfMoneyMoneyClosed()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Config.moneyMoneyBundleId {
                Task {
                    await self?.handleMoneyMoneyLaunch()
                }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Config.moneyMoneyBundleId {
                Task {
                    await self?.startSync()
                }
            }
        }
    }

    private func addLog(_ message: String, level: LogLevel = .info) {
        logger.log("\(message, privacy: .public)")
        logs.insert(LogEntry(timestamp: Date(), level: level, message: message), at: 0)
        if logs.count > maxLogEntries {
            logs.removeLast()
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func checkICloudAvailability() {
        isICloudAvailable = FileManager.default.fileExists(atPath: Config.iCloudDriveURL.path)
    }

    // MARK: - MoneyMoney lifecycle

    private func handleMoneyMoneyLaunch() async {
        checkICloudAvailability()
        guard isICloudAvailable else { return }
        do {
            if let other = try engine.acquireLock() {
                let message = "MoneyMoney is also open on \(other.mac). Changes on both Macs will conflict."
                addLog(message, level: .warning)
                sendNotification(title: "MoneyMoney open elsewhere", body: message)
            } else if engine.remoteIsNewer() {
                let message = "iCloud has newer data. Quit MoneyMoney and let mmSync update before making changes."
                addLog(message, level: .warning)
                sendNotification(title: "Newer data in iCloud", body: message)
            } else {
                addLog("MoneyMoney opened, lock taken")
            }
        } catch {
            addLog("Failed to write lock: \(error.localizedDescription)", level: .error)
        }
    }

    private func syncIfMoneyMoneyClosed() async {
        if isMoneyMoneyRunning() {
            // Keep the lock held, e.g. after mmSync restarted while MoneyMoney was open.
            checkICloudAvailability()
            if isICloudAvailable {
                _ = try? engine.acquireLock()
            }
        } else {
            await startSync()
        }
    }

    // MARK: - Sync

    public func startSync() async {
        await run { try $0.sync() }
    }

    /// Conflict resolution: keep the iCloud version, back up this Mac's database.
    public func useICloudVersion() async {
        await run { try $0.forcePull() }
    }

    /// Conflict resolution: keep this Mac's version, back up the iCloud database.
    public func useThisMacsVersion() async {
        await run { try $0.forcePush() }
    }

    public func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func promptForFullDiskAccess() {
        let alert = NSAlert()
        alert.messageText = "mmSync needs Full Disk Access"
        alert.informativeText = "macOS blocks access to MoneyMoney's data. Add mmSync under Privacy & Security → Full Disk Access, then restart mmSync."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openFullDiskAccessSettings()
        }
    }

    // MARK: - Login item

    public func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            addLog(enabled ? "Registered to open at login" : "Removed from login items")
        } catch {
            addLog("Failed to change login item: \(error.localizedDescription)", level: .error)
        }
        refreshLoginItemStatus()
    }

    /// The user can change this in System Settings → General → Login Items at any time.
    public func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func showBackupsInFinder() {
        try? FileManager.default.createDirectory(at: Config.syncURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.syncURL)
    }

    private func run(_ work: @escaping @Sendable (SyncEngine) throws -> SyncOutcome) async {
        guard !isSyncing else { return }
        checkICloudAvailability()
        guard isICloudAvailable else { return fail(SyncError.iCloudNotAvailable) }
        guard !isMoneyMoneyRunning() else { return fail(SyncError.moneyMoneyRunning) }

        isSyncing = true
        syncStatus = .syncing
        defer { isSyncing = false }

        let engine = self.engine
        do {
            let outcome = try await Task.detached { try work(engine) }.value
            engine.releaseLock()
            hasConflict = false
            needsFullDiskAccess = false
            lastSyncTime = engine.lastSynced()?.date

            switch outcome {
            case .upToDate:
                syncStatus = .success("Up to date")
            case .pushed:
                syncStatus = .success("Uploaded to iCloud")
                addLog("Uploaded database to iCloud")
                sendNotification(title: Config.notificationTitle, body: "MoneyMoney data uploaded to iCloud.")
            case .pulled:
                syncStatus = .success("Updated from iCloud")
                addLog("Replaced local database with iCloud version")
                sendNotification(title: Config.notificationTitle, body: "MoneyMoney data updated from iCloud.")
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        if case .conflictDetected = error as? SyncError { hasConflict = true }
        if case .noAccess = error as? SyncError {
            // Once per occurrence; the flag resets after the next successful sync.
            if !needsFullDiskAccess { promptForFullDiskAccess() }
            needsFullDiskAccess = true
        }

        // The poll timer retries every few minutes; only notify when the problem changes.
        if syncStatus != .error(message) {
            addLog("Sync failed: \(message)", level: .error)
            sendNotification(title: "Sync Error", body: message)
        }
        syncStatus = .error(message)
    }

    private func isMoneyMoneyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Config.moneyMoneyBundleId && !$0.isTerminated
        }
    }

    /// nil resets to the default location.
    public func setMoneyMoneyDataURL(_ url: URL?) {
        guard !isSyncing else { return }
        UserDefaults.standard.set(url, forKey: Config.moneyMoneyDataURLKey)
        engine = Self.makeEngine()
        addLog("MoneyMoney data folder: \(Config.moneyMoneyDataURL.path)")
    }

    private static func makeEngine() -> SyncEngine {
        SyncEngine(
            localDatabase: Config.moneyMoneyDataURL.appending(path: "Database"),
            remoteRoot: Config.syncURL,
            stateDirectory: Config.stateURL,
            mac: Host.current().localizedName ?? "Unknown",
            moneyMoneyVersion: moneyMoneyVersion(),
            maxLocalBackups: Config.maxLocalBackups
        )
    }

    private static func moneyMoneyVersion() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.moneyMoneyBundleId)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }
}

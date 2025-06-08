import Foundation

enum Config {
    static let moneyMoneyBundleId = "com.moneymoney-app.retail"
    static let appGroupId = "group.com.piofresco.mmsync"
    
    static let moneyMoneyPath = "/Users/\(NSUserName())/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support"
    static let iCloudBackupPath = "/Users/\(NSUserName())/Library/Mobile Documents/com~apple~CloudDocs/Backups/MoneyMoney"
    
    static var defaultSourcePath: String {
        moneyMoneyPath
    }
    
    static var defaultDestinationPath: String {
        iCloudBackupPath
    }
    
    static func backupFolderPath() -> String {
        let computerName = Host.current().localizedName ?? "unknown"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = dateFormatter.string(from: Date())
        return "\(iCloudBackupPath)/\(timestamp)_\(computerName)"
    }
    
    static func lockFilePath() -> String {
        let computerName = Host.current().localizedName ?? "unknown"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = dateFormatter.string(from: Date())
        return "\(iCloudBackupPath)/\(timestamp)_\(computerName).mmSyncLockFile"
    }
    
    static let requiredDirectories = [
        "Database",
        "Backup",
        "Export"
    ]
    
    static let requiredDatabaseFiles = [
        "MoneyMoney.sqlite",
        "MoneyMoney.sqlite-shm",
        "MoneyMoney.sqlite-wal"
    ]
    
    static let staleLockTimeout: TimeInterval = 4 * 60 * 60 // 4 hours
    static let maxBackups = 3
    
    static let notificationTitle = "mmSync"
    static let notificationSound = "default"
} 
import Foundation

enum Config {
    static let moneyMoneyBundleId = "com.moneymoney-app.retail"

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// MoneyMoney → Help → Show Database in Finder
    static let defaultMoneyMoneyDataURL = home.appending(path: "Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney")
    static let moneyMoneyDataURLKey = "moneyMoneyDataURL"
    /// User-chosen folder from Settings, else the default location.
    static var moneyMoneyDataURL: URL {
        UserDefaults.standard.url(forKey: moneyMoneyDataURLKey) ?? defaultMoneyMoneyDataURL
    }

    static func isMoneyMoneyDataDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "Database/MoneyMoney.sqlite").path)
    }
    static let iCloudDriveURL = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    static let syncURL = iCloudDriveURL.appending(path: "Backups/MoneyMoney")
    static let stateURL = home.appending(path: "Library/Application Support/mmSync")

    /// Set once mmSync has registered itself as a login item, so turning it off in Settings sticks.
    static let didSetUpLoginItemKey = "didSetUpLoginItem"

    static let pollInterval: TimeInterval = 5 * 60
    static let maxLocalBackups = 3

    static let notificationTitle = "mmSync"
}

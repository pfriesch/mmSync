import Foundation

enum Config {
    static let moneyMoneyBundleId = "com.moneymoney-app.retail"

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// MoneyMoney → Help → Show Database in Finder
    static let moneyMoneyDataURL = home.appending(path: "Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney")
    static let iCloudDriveURL = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    static let syncURL = iCloudDriveURL.appending(path: "Backups/MoneyMoney")
    static let stateURL = home.appending(path: "Library/Application Support/mmSync")

    static let pollInterval: TimeInterval = 5 * 60
    static let maxLocalBackups = 3

    static let notificationTitle = "mmSync"
}

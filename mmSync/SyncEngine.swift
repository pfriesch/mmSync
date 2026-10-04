import Foundation
import CryptoKit

/// Describes one uploaded copy of MoneyMoney's `Database/` folder.
struct Manifest: Codable, Equatable {
    var id = UUID()
    var mac: String
    var date: Date
    var moneyMoneyVersion: String?
    var files: [String: String] // relative path → SHA-256
}

/// Marks that MoneyMoney is open on some Mac. Advisory only: iCloud delivers it with delay.
struct Lock: Codable, Equatable {
    var mac: String
    var date: Date
}

enum SyncOutcome: Equatable {
    case upToDate, pushed, pulled
}

/// Whole-folder sync of MoneyMoney's database via a shared folder (iCloud Drive).
///
/// Remote layout:
///   <remoteRoot>/current/Database/…        last uploaded database
///   <remoteRoot>/current/manifest.json     hashes of the files above
///   <remoteRoot>/LOCK                      who has MoneyMoney open
///
/// Local state:
///   <stateDirectory>/manifest.json         manifest this Mac last pushed or pulled
///   <stateDirectory>/Backups/<timestamp>   copies taken before anything is overwritten
///
/// All sync methods expect MoneyMoney to be closed on this Mac.
struct SyncEngine {
    let localDatabase: URL
    let remoteRoot: URL
    let stateDirectory: URL
    let mac: String
    var moneyMoneyVersion: String?
    var maxLocalBackups = 3

    private var fm: FileManager { .default }
    private var remoteCurrent: URL { remoteRoot.appending(path: "current") }
    private var remoteDatabase: URL { remoteCurrent.appending(path: "Database") }
    private var remoteManifestURL: URL { remoteCurrent.appending(path: "manifest.json") }
    private var lockURL: URL { remoteRoot.appending(path: "LOCK") }
    private var lastSyncedURL: URL { stateDirectory.appending(path: "manifest.json") }
    var backupsURL: URL { stateDirectory.appending(path: "Backups") }

    // MARK: - State

    func lastSynced() -> Manifest? {
        try? read(Manifest.self, from: lastSyncedURL)
    }

    func remoteManifest() throws -> Manifest? {
        guard fm.fileExists(atPath: remoteManifestURL.path) else { return nil }
        return try read(Manifest.self, from: remoteManifestURL)
    }

    /// True when another Mac pushed something this Mac hasn't pulled yet.
    func remoteIsNewer() -> Bool {
        guard let remote = try? remoteManifest() else { return false }
        return remote.id != lastSynced()?.id
    }

    // MARK: - Lock

    func currentLock() -> Lock? {
        try? read(Lock.self, from: lockURL)
    }

    /// Takes the lock. Returns the previous holder if it was another Mac.
    @discardableResult
    func acquireLock() throws -> Lock? {
        let previous = currentLock()
        try fm.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try write(Lock(mac: mac, date: .now), to: lockURL)
        return previous?.mac == mac ? nil : previous
    }

    func releaseLock() {
        if currentLock()?.mac == mac {
            try? fm.removeItem(at: lockURL)
        }
    }

    // MARK: - Sync

    func sync() throws -> SyncOutcome {
        if let lock = currentLock(), lock.mac != mac {
            throw SyncError.lockedBy(lock.mac, lock.date)
        }
        let local = try localHashes()
        let last = lastSynced()
        let remote = try remoteManifest()

        // An empty local folder (fresh Mac) never counts as a change worth keeping.
        let localChanged = !local.isEmpty && local != last?.files
        let remoteChanged = remote != nil && remote?.id != last?.id

        switch (localChanged, remoteChanged) {
        case (false, false):
            return .upToDate
        case (true, false):
            try push()
            return .pushed
        case (false, true):
            try pull(remote!)
            return .pulled
        case (true, true):
            if local == remote!.files {
                try write(remote!, to: lastSyncedURL)
                return .upToDate
            }
            throw SyncError.conflictDetected
        }
    }

    /// Conflict resolution: replace this Mac's database with the iCloud copy (local copy is backed up).
    func forcePull() throws -> SyncOutcome {
        guard let remote = try remoteManifest() else { throw SyncError.noBackupFound }
        try pull(remote)
        return .pulled
    }

    /// Conflict resolution: replace the iCloud copy with this Mac's database (iCloud copy is backed up).
    func forcePush() throws -> SyncOutcome {
        try push()
        return .pushed
    }

    // MARK: - Push / pull

    /// Backs up the iCloud copy it replaces, so a bad upload can be undone.
    private func push() throws {
        if fm.fileExists(atPath: remoteDatabase.path) {
            try backup(remoteDatabase, suffix: "_icloud")
        }
        let tmp = remoteRoot.appending(path: "current.tmp-\(mac)")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fm.copyItem(at: localDatabase, to: tmp.appending(path: "Database"))

        let manifest = Manifest(
            mac: mac,
            date: .now,
            moneyMoneyVersion: moneyMoneyVersion,
            files: try hashes(of: tmp.appending(path: "Database"))
        )
        // Manifest goes in last so a complete `current/` always has one.
        try write(manifest, to: tmp.appending(path: "manifest.json"))

        try? fm.removeItem(at: remoteCurrent)
        try fm.moveItem(at: tmp, to: remoteCurrent)
        try write(manifest, to: lastSyncedURL)
    }

    private func pull(_ remote: Manifest) throws {
        // iCloud may deliver the manifest before the files; hashes catch that.
        guard try hashes(of: remoteDatabase) == remote.files else {
            throw SyncError.iCloudNotReady
        }
        let parent = localDatabase.deletingLastPathComponent()
        let tmp = parent.appending(path: "Database.mmsync-tmp")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: remoteDatabase, to: tmp)
        guard try hashes(of: tmp) == remote.files else {
            try? fm.removeItem(at: tmp)
            throw SyncError.iCloudNotReady
        }

        if fm.fileExists(atPath: localDatabase.path) {
            try backup(localDatabase, suffix: "")
            try fm.removeItem(at: localDatabase)
        }
        try fm.moveItem(at: tmp, to: localDatabase)
        try write(remote, to: lastSyncedURL)
    }

    private func backup(_ folder: URL, suffix: String) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let target = backupsURL.appending(path: formatter.string(from: .now) + suffix)
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: folder, to: target)

        // Timestamped names sort chronologically.
        let all = try fm.contentsOfDirectory(atPath: backupsURL.path).filter { !$0.hasPrefix(".") }.sorted()
        for name in all.dropLast(maxLocalBackups) {
            try? fm.removeItem(at: backupsURL.appending(path: name))
        }
    }

    // MARK: - Helpers

    private func localHashes() throws -> [String: String] {
        do {
            return try hashes(of: localDatabase)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw SyncError.noAccess
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(error.code)) {
            throw SyncError.noAccess
        }
    }

    /// SHA-256 of every regular file below `folder`, keyed by relative path. Missing folder → empty.
    func hashes(of folder: URL) throws -> [String: String] {
        guard fm.fileExists(atPath: folder.path) else { return [:] }
        // Throws on permission errors, unlike the enumerator below.
        _ = try fm.contentsOfDirectory(atPath: folder.path)

        var result: [String: String] = [:]
        let enumerator = fm.enumerator(atPath: folder.path)
        while let relative = enumerator?.nextObject() as? String {
            guard enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  !relative.hasSuffix(".DS_Store") else { continue }
            let handle = try FileHandle(forReadingFrom: folder.appending(path: relative))
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            result[relative] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

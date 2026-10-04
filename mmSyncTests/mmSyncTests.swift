//
//  mmSyncTests.swift
//  mmSyncTests
//
//  Created by Pius Friesch on 29.05.25.
//

import Foundation
import Testing
@testable import mmSync

/// Two Macs sharing one fake "iCloud" folder.
struct SyncEngineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mmSyncTests-\(UUID())")

    func mac(_ name: String) -> SyncEngine {
        SyncEngine(
            localDatabase: root.appending(path: "\(name)/MoneyMoney/Database"),
            remoteRoot: root.appending(path: "iCloud"),
            stateDirectory: root.appending(path: "\(name)/state"),
            mac: name
        )
    }

    func write(_ text: String, to engine: SyncEngine) throws {
        try FileManager.default.createDirectory(at: engine.localDatabase, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: engine.localDatabase.appending(path: "MoneyMoney.sqlite"))
    }

    func read(_ engine: SyncEngine) throws -> String {
        try String(contentsOf: engine.localDatabase.appending(path: "MoneyMoney.sqlite"), encoding: .utf8)
    }

    @Test func roundTripBetweenMacs() throws {
        let a = mac("A"), b = mac("B")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try b.sync() == .upToDate) // nothing anywhere yet

        try write("v1", to: a)
        #expect(try a.sync() == .pushed)
        #expect(try a.sync() == .upToDate)

        #expect(try b.sync() == .pulled) // fresh Mac gets the data
        #expect(try read(b) == "v1")

        try write("v2", to: b)
        #expect(try b.sync() == .pushed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: b.backupsURL.path).count == 1) // replaced iCloud v1
        #expect(a.remoteIsNewer())
        #expect(try a.sync() == .pulled)
        #expect(try read(a) == "v2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.backupsURL.path).count == 1)
    }

    @Test func conflictKeepsBothUntilResolved() throws {
        let a = mac("A"), b = mac("B")
        defer { try? FileManager.default.removeItem(at: root) }

        try write("v1", to: a)
        _ = try a.sync()
        _ = try b.sync()

        try write("from A", to: a)
        try write("from B", to: b)
        #expect(try a.sync() == .pushed)
        #expect(throws: SyncError.self) { try b.sync() }
        #expect(try read(b) == "from B") // nothing overwritten

        #expect(try b.forcePull() == .pulled)
        #expect(try read(b) == "from A")
        #expect(try b.sync() == .upToDate)
    }

    @Test func foreignLockBlocksSync() throws {
        let a = mac("A"), b = mac("B")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try a.acquireLock() == nil)
        #expect(try b.acquireLock()?.mac == "A")
        #expect(throws: SyncError.self) { try a.sync() }
        b.releaseLock()
        #expect(a.currentLock() == nil)
        #expect(try a.sync() == .upToDate)
    }
}

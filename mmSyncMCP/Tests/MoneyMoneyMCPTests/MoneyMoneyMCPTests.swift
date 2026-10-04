import Foundation
import Testing
@testable import MoneyMoneyMCP

/// Records scripts and answers with canned output instead of calling `osascript`.
final class MockRunner {
    var scripts: [String] = []
    var respond: (String) throws -> String = { _ in "" }
    lazy var run: ScriptRunner = { [unowned self] script in
        scripts.append(script)
        return try respond(script)
    }
}

func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
    let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
    let response = try #require(server.handle(String(decoding: request, as: UTF8.self)))
    return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
}

func toolText(_ response: [String: Any]) -> (text: String, isError: Bool) {
    let result = response["result"] as? [String: Any] ?? [:]
    let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    return (content, result["isError"] as? Bool ?? false)
}

let transactionsPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>transactions</key><array>
  <dict><key>name</key><string>REWE</string><key>amount</key><real>-23.5</real><key>bookingDate</key><date>2026-09-01T10:00:00Z</date></dict>
  <dict><key>name</key><string>Landlord</string><key>purpose</key><string>Miete Oktober</string><key>amount</key><real>-900</real><key>bookingDate</key><date>2026-10-01T10:00:00Z</date></dict>
  <dict><key>name</key><string>Rewe Markt</string><key>amount</key><real>-12</real><key>bookingDate</key><date>2026-10-02T10:00:00Z</date></dict>
</array></dict></plist>
"""

struct MCPProtocolTests {
    let server = MCPServer(name: "test", version: "1", tools: MoneyMoney(run: { _ in "" }).tools)

    @Test func initializeNegotiatesVersion() throws {
        let known = try call(server, "initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any]
        #expect(known?["protocolVersion"] as? String == "2025-06-18")
        let unknown = try call(server, "initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any]
        #expect(unknown?["protocolVersion"] as? String == MCPServer.supportedVersions.last)
    }

    @Test func notificationsGetNoResponse() {
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func listsToolsWithAnnotations() throws {
        let tools = try #require((try call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 7)
        let readOnly = tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }
        #expect(readOnly.map { $0["name"] as? String } .contains("create_bank_transfer") == false)
        #expect(readOnly.count == 5)
        let destructive = tools.filter { ($0["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true }
        #expect(destructive.map { $0["name"] as? String } == ["set_transaction"])
    }

    @Test func unknownMethodAndToolAreErrors() throws {
        #expect((try call(server, "resources/list")["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect((try call(server, "tools/call", ["name": "nope"])["error"] as? [String: Any])?["code"] as? Int == -32602)
    }
}

struct MoneyMoneyToolTests {
    @Test(arguments: [
        ("execution error: MoneyMoney got an error: Locked database. (-2720)", MoneyMoneyError.databaseLocked),
        ("execution error: MoneyMoney isn't running. (-600)", .notRunning),
        ("execution error: Not authorized to send Apple events to MoneyMoney. (-1743)", .automationDenied),
        ("something else", .script("something else")),
    ])
    func classifiesErrors(stderr: String, expected: MoneyMoneyError) {
        #expect(MoneyMoneyError.classify(stderr: stderr) == expected)
    }

    @Test func lockedDatabaseBecomesToolError() throws {
        let server = MCPServer(name: "t", version: "1", tools: MoneyMoney(run: { _ in throw MoneyMoneyError.databaseLocked }).tools)
        let (text, isError) = toolText(try call(server, "tools/call", ["name": "export_accounts"]))
        #expect(isError)
        #expect(text.contains("locked"))
    }

    @Test func commandsNeverLaunchMoneyMoney() throws {
        let mock = MockRunner()
        mock.respond = { _ in "<plist version=\"1.0\"><array/></plist>" }
        _ = try MoneyMoney(run: mock.run).plist(MoneyMoney(run: mock.run).command("export accounts"))
        #expect(mock.scripts[0].hasPrefix(#"if application "MoneyMoney" is not running then error"#))
    }

    @Test func transactionsFilterSortLimitAndConvertDates() throws {
        let mock = MockRunner()
        mock.respond = { _ in transactionsPlist }
        let result = try MoneyMoney(run: mock.run).exportTransactions([
            "account": #"Giro "Haupt""#, "from_date": "2026-09-01", "search": "rewe", "limit": 1,
        ])
        #expect(result["total"] as? Int == 2)
        let transactions = try #require(result["transactions"] as? [[String: Any]])
        #expect(transactions.count == 1)
        #expect(transactions[0]["name"] as? String == "Rewe Markt") // newest first
        #expect(transactions[0]["bookingDate"] as? String == "2026-10-02T10:00:00Z")
        #expect(mock.scripts[0].contains(#"from account "Giro \"Haupt\"" from date "2026-09-01" to date ""#))
        #expect(mock.scripts[0].hasSuffix(#"as "plist""#))
    }

    @Test func transferBuildsScriptAndRejectsBadInput() throws {
        let mock = MockRunner()
        let mm = MoneyMoney(run: mock.run)
        let message = try mm.createBankTransfer([
            "from_account": "Giro", "to": "Alice", "iban": "de89 3704 0044 0532 0130 00", "amount": 12.3, "purpose": "Rent",
        ])
        #expect(message.contains("Nothing has been sent"))
        #expect(mock.scripts[0].contains(#"create bank transfer from account "Giro" to "Alice" iban "DE89370400440532013000" amount 12.30 purpose "Rent""#))
        #expect(!mock.scripts[0].contains("outbox"))

        let valid: [String: Any] = ["from_account": "Giro", "to": "Alice", "iban": "DE89370400440532013000", "amount": 5]
        #expect(throws: MoneyMoneyError.self) { try mm.createBankTransfer(valid.merging(["amount": -5]) { $1 }) }
        #expect(throws: MoneyMoneyError.self) { try mm.createBankTransfer(valid.merging(["iban": "not an iban"]) { $1 }) }
        #expect(throws: MoneyMoneyError.self) { try mm.createBankTransfer(valid.merging(["purpose": "a\nb"]) { $1 }) }
        #expect(throws: MoneyMoneyError.self) { try mm.createBankTransfer(valid.merging(["scheduled_date": "2026-13-45"]) { $1 }) }
        #expect(mock.scripts.count == 1) // invalid input never reaches MoneyMoney
    }

    @Test func setTransactionBuildsScriptAndRejectsBadInput() throws {
        let mock = MockRunner()
        let mm = MoneyMoney(run: mock.run)
        _ = try mm.setTransaction(["id": 42, "checkmark": true, "category": #"Ausgaben\Lebensmittel"#, "comment": #"say "hi""#])
        #expect(mock.scripts[0].hasSuffix(#"set transaction id 42 checkmark to "on" category to "Ausgaben\\Lebensmittel" comment to "say \"hi\"""#))
        _ = try mm.setTransaction(["id": 42, "comment": ""])
        #expect(mock.scripts[1].hasSuffix(#"set transaction id 42 comment to """#)) // empty clears

        #expect(throws: MoneyMoneyError.self) { try mm.setTransaction(["id": 42]) } // nothing to change
        #expect(throws: MoneyMoneyError.self) { try mm.setTransaction(["id": "42", "comment": "x"]) }
        #expect(throws: MoneyMoneyError.self) { try mm.setTransaction(["id": 42, "comment": "a\nb"]) }
        #expect(mock.scripts.count == 2)
    }

    @Test func initializeAdvertisesIcon() throws {
        let icon: [String: Any] = ["src": "data:image/svg+xml;base64,AA==", "mimeType": "image/svg+xml", "sizes": ["any"]]
        let server = MCPServer(name: "t", version: "1", tools: [], icons: [icon])
        let info = (try call(server, "initialize")["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect((info?["icons"] as? [[String: Any]])?.first?["mimeType"] as? String == "image/svg+xml")
    }

    @Test func statusReportsLockedDatabase() throws {
        let mock = MockRunner()
        mock.respond = { script in
            if script == #"application "MoneyMoney" is running"# { return "true" }
            if script.hasSuffix("get version") { return "2.4.53" }
            throw MoneyMoneyError.databaseLocked
        }
        let status = try MoneyMoney(run: mock.run).status()
        #expect(status["running"] as? Bool == true)
        #expect(status["unlocked"] as? Bool == false)
        #expect(status["version"] as? String == "2.4.53")
    }
}

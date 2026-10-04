import Foundation

public enum MoneyMoneyError: LocalizedError, Equatable {
    case notRunning
    case databaseLocked
    case automationDenied
    case invalidArgument(String)
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "MoneyMoney isn't running. Start it and unlock the database, then try again."
        case .databaseLocked:
            return "MoneyMoney's database is locked. Unlock it in MoneyMoney (password or Touch ID), then try again."
        case .automationDenied:
            return "Not allowed to control MoneyMoney. Allow it in System Settings → Privacy & Security → Automation."
        case .invalidArgument(let message):
            return message
        case .script(let message):
            return "AppleScript error: \(message)"
        }
    }

    /// Maps `osascript` stderr to an error the model can act on.
    static func classify(stderr: String) -> MoneyMoneyError {
        if stderr.contains("(-2720)") || stderr.contains("Locked database") { return .databaseLocked }
        if stderr.contains("(-600)") || stderr.contains("isn't running") { return .notRunning }
        if stderr.contains("(-1743)") || stderr.contains("Not authorized") { return .automationDenied }
        return .script(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Runs an AppleScript and returns its stdout. Tests pass a closure instead of `osascript`.
public typealias ScriptRunner = (String) throws -> String

public func osascript(_ script: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Read before waiting: large exports would otherwise fill the pipe and deadlock.
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MoneyMoneyError.classify(stderr: String(decoding: stderr, as: UTF8.self))
    }
    return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
}

/// MoneyMoney's AppleScript interface as MCP tools.
/// Read tools are side-effect free. Writes: `create_bank_transfer` only opens a window the user confirms
/// with a TAN; `set_transaction` overwrites immediately and is marked destructive.
public struct MoneyMoney {
    let run: ScriptRunner

    public init(run: @escaping ScriptRunner = osascript) {
        self.run = run
    }

    /// Sends one command to MoneyMoney. Never launches it: a plain `tell` would start the app,
    /// which would also bypass mmSync's lock on other Macs.
    func command(_ command: String) throws -> String {
        try run("""
        if application "MoneyMoney" is not running then error "MoneyMoney isn't running." number -600
        tell application "MoneyMoney" to \(command)
        """)
    }

    // MARK: - Tools

    public var tools: [Tool] {
        let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]
        return [
            Tool(
                name: "status",
                description: "Report whether MoneyMoney is running and its database is unlocked. Returns {running, unlocked, version}. Call this first when other tools fail.",
                inputSchema: schema([:]),
                annotations: readOnly,
                handler: { _ in try status() }
            ),
            Tool(
                name: "export_accounts",
                description: "List all MoneyMoney accounts and account groups: {uuid, name, bankCode, accountNumber (IBAN), balance [[amount, currency]], group, portfolio, ...}.",
                inputSchema: schema([:]),
                annotations: readOnly,
                handler: { _ in try plist(command("export accounts")) }
            ),
            Tool(
                name: "export_categories",
                description: "List the MoneyMoney category tree: {uuid, name, group, indentation, budget, ...}. Hierarchy is given by indentation and order.",
                inputSchema: schema([:]),
                annotations: readOnly,
                handler: { _ in try plist(command("export categories")) }
            ),
            Tool(
                name: "export_transactions",
                description: "List transactions, newest first. Defaults to the last 90 days and 200 results. Returns {total, returned, transactions: [{id, bookingDate, valueDate, amount, currency, name, purpose, category, comment, checkmark, ...}]}.",
                inputSchema: schema([
                    "account": ["type": "string", "description": "UUID, IBAN, account number, account name or account group name. Omit for all accounts."],
                    "category": ["type": "string", "description": "UUID or category name. Nested names are separated with backslashes."],
                    "from_date": ["type": "string", "description": "YYYY-MM-DD. Default: 90 days ago."],
                    "to_date": ["type": "string", "description": "YYYY-MM-DD. Default: today."],
                    "search": ["type": "string", "description": "Case-insensitive text matched against all text fields (name, purpose, comment, category, ...)."],
                    "limit": ["type": "integer", "description": "Maximum number of transactions to return. Default 200."],
                ]),
                annotations: readOnly,
                handler: { try exportTransactions($0) }
            ),
            Tool(
                name: "export_portfolio",
                description: "List securities held in portfolio (Depot) accounts: {name, isin, wkn, quantity, price, amount, purchasePrice, ...}.",
                inputSchema: schema([
                    "account": ["type": "string", "description": "UUID, IBAN, account number or account name. Omit for all portfolios."],
                ]),
                annotations: readOnly,
                handler: { try exportPortfolio($0) }
            ),
            Tool(
                name: "create_bank_transfer",
                description: "Draft a SEPA bank transfer. Opens a pre-filled payment window in MoneyMoney; nothing is sent until the user reviews it and confirms with a TAN in MoneyMoney. Never saves silently to the outbox.",
                inputSchema: schema([
                    "from_account": ["type": "string", "description": "Sending account: UUID, IBAN, account number or account name."],
                    "iban": ["type": "string", "description": "Recipient IBAN."],
                    "amount": ["type": "number", "description": "Amount in euros, greater than 0."],
                    "to": ["type": "string", "description": "Recipient name."],
                    "bic": ["type": "string", "description": "Recipient BIC (optional for SEPA)."],
                    "purpose": ["type": "string", "description": "Purpose text (Verwendungszweck)."],
                    "endtoend_reference": ["type": "string", "description": "SEPA end-to-end reference."],
                    "scheduled_date": ["type": "string", "description": "YYYY-MM-DD for a scheduled transfer."],
                ], required: ["from_account", "iban", "amount", "to"]),
                annotations: ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
                handler: { try createBankTransfer($0) }
            ),
            Tool(
                name: "set_transaction",
                description: "Change the checkmark, category and/or comment of one transaction. SILENT OVERWRITE: applied immediately with no confirmation in MoneyMoney and no undo, so confirm the change with the user first and report the previous values from export_transactions.",
                inputSchema: schema([
                    "id": ["type": "integer", "description": "Transaction id from export_transactions."],
                    "checkmark": ["type": "boolean", "description": "Set or clear the checkmark."],
                    "category": ["type": "string", "description": "UUID or category name. Nested names are separated with backslashes."],
                    "comment": ["type": "string", "description": "New comment. An empty string clears it."],
                ], required: ["id"]),
                annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false],
                handler: { try setTransaction($0) }
            ),
        ]
    }

    // MARK: - Handlers

    func status() throws -> [String: Any] {
        let running = try run(#"application "MoneyMoney" is running"#) == "true"
        guard running else { return ["running": false, "unlocked": false] }
        var result: [String: Any] = ["running": true, "unlocked": true]
        result["version"] = try? command("get version")
        do {
            _ = try command("export categories") // cheap probe: fails with -2720 while locked
        } catch MoneyMoneyError.databaseLocked {
            result["unlocked"] = false
        }
        return result
    }

    func exportTransactions(_ args: [String: Any]) throws -> [String: Any] {
        let day = DateFormatter.day
        let from = try date(args["from_date"]) ?? day.string(from: Date(timeIntervalSinceNow: -90 * 86_400))
        let to = try date(args["to_date"]) ?? day.string(from: Date())
        let limit = args["limit"] as? Int ?? 200

        var parts = ["export transactions"]
        if let account = try text(args["account"]) { parts.append("from account \(quote(account))") }
        if let category = try text(args["category"]) { parts.append("from category \(quote(category))") }
        parts += ["from date \(quote(from))", "to date \(quote(to))", #"as "plist""#]

        let root = try PropertyListSerialization.propertyList(from: Data(command(parts.joined(separator: " ")).utf8), format: nil)
        var transactions = (root as? [String: Any])?["transactions"] as? [[String: Any]] ?? []

        if let search = try text(args["search"])?.lowercased() {
            transactions = transactions.filter { transaction in
                transaction.values.contains { ($0 as? String)?.lowercased().contains(search) == true }
            }
        }
        transactions.sort {
            ($0["bookingDate"] as? Date ?? .distantPast) > ($1["bookingDate"] as? Date ?? .distantPast)
        }
        return [
            "total": transactions.count,
            "returned": min(limit, transactions.count),
            "transactions": jsonSafe(Array(transactions.prefix(limit))),
        ]
    }

    func exportPortfolio(_ args: [String: Any]) throws -> Any {
        var parts = ["export portfolio"]
        if let account = try text(args["account"]) { parts.append("from account \(quote(account))") }
        parts.append(#"as "plist""#)
        return try plist(command(parts.joined(separator: " ")))
    }

    func createBankTransfer(_ args: [String: Any]) throws -> String {
        guard let from = try text(args["from_account"]) else { throw MoneyMoneyError.invalidArgument("from_account is required.") }
        guard let to = try text(args["to"]) else { throw MoneyMoneyError.invalidArgument("to (recipient name) is required.") }
        guard let rawIBAN = try text(args["iban"]) else { throw MoneyMoneyError.invalidArgument("iban is required.") }
        let iban = rawIBAN.replacingOccurrences(of: " ", with: "").uppercased()
        guard iban.range(of: #"^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$"#, options: .regularExpression) != nil else {
            throw MoneyMoneyError.invalidArgument("iban doesn't look like an IBAN: \(rawIBAN)")
        }
        guard let amount = (args["amount"] as? NSNumber)?.doubleValue, amount > 0, amount.isFinite else {
            throw MoneyMoneyError.invalidArgument("amount must be a number greater than 0.")
        }

        var parts = [
            "create bank transfer from account \(quote(from))",
            "to \(quote(to))",
            "iban \(quote(iban))",
            "amount \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount))",
        ]
        if let bic = try text(args["bic"]) { parts.append("bic \(quote(bic))") }
        if let purpose = try text(args["purpose"]) { parts.append("purpose \(quote(purpose))") }
        if let reference = try text(args["endtoend_reference"]) { parts.append("endtoend reference \(quote(reference))") }
        if let scheduled = try date(args["scheduled_date"]) { parts.append("scheduled date \(quote(scheduled))") }

        _ = try command(parts.joined(separator: " "))
        return "Transfer window opened in MoneyMoney. Nothing has been sent: the user must review it and confirm with a TAN in MoneyMoney."
    }

    func setTransaction(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? Int, id > 0 else {
            throw MoneyMoneyError.invalidArgument("id must be the integer transaction id from export_transactions.")
        }
        var parts = ["set transaction id \(id)"]
        if let checkmark = args["checkmark"] as? Bool { parts.append("checkmark to \(quote(checkmark ? "on" : "off"))") }
        if let category = try text(args["category"]) { parts.append("category to \(quote(category))") }
        if args["comment"] is String { parts.append("comment to \(quote(try text(args["comment"]) ?? ""))") }
        guard parts.count > 1 else {
            throw MoneyMoneyError.invalidArgument("Pass at least one of checkmark, category or comment.")
        }

        _ = try command(parts.joined(separator: " "))
        return "Transaction \(id) updated."
    }

    // MARK: - Helpers

    func plist(_ xml: String) throws -> Any {
        jsonSafe(try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil))
    }

    /// Optional string argument; rejects line breaks so nothing can break out of the script line.
    func text(_ value: Any?) throws -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        guard !string.contains(where: \.isNewline) else {
            throw MoneyMoneyError.invalidArgument("Text arguments must not contain line breaks.")
        }
        return string
    }

    func date(_ value: Any?) throws -> String? {
        guard let string = try text(value) else { return nil }
        guard DateFormatter.day.date(from: string) != nil else {
            throw MoneyMoneyError.invalidArgument("Dates must be YYYY-MM-DD, got \(string).")
        }
        return string
    }

    /// AppleScript string literal.
    func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
}

/// Property-list values that JSON can't hold: dates → ISO 8601, data → base64.
func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]: return dict.mapValues(jsonSafe)
    case let array as [Any]: return array.map(jsonSafe)
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let data as Data: return data.base64EncodedString()
    default: return value
    }
}

extension DateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

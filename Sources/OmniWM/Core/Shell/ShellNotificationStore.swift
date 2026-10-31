// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import SQLite3

enum ShellNotificationStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    enum Failure: Error {
        case query
        case malformed(ShellNotificationReadIssue.Reason)
    }

    private typealias Budget = ShellNotificationReadBudget

    private struct RecordContext {
        let appID: Int64
        let bundle: String
        let retained: Set<String>
        let categories: ShellServiceValue
    }

    private struct Tables {
        let apps: [[String: Column]]
        let categories: [[String: Column]]
        let lists: [String: [[String: Column]]]
        let memberships: [Int64: Set<String>]
        let records: [[String: Column]]
    }

    private struct Collected {
        var apps: [ShellServiceValue] = []
        var items: [ShellServiceValue] = []
        var found: [Int64: Set<String>] = [:]
    }

    static func read(at url: URL = defaultURL) -> ShellNotificationsData {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            let denied = opened == SQLITE_AUTH || opened == SQLITE_PERM ||
                (database.map { [EACCES, EPERM].contains(sqlite3_system_errno($0)) } ?? false)
            return ShellNotificationsData(
                state: denied ? "accessDenied" : "unavailable",
                complete: false,
                error: denied ? "Notification storage access denied" : "Notification storage unavailable"
            )
        }
        do {
            guard sqlite3_db_readonly(database, "main") == 1 else { throw Failure.query }
            try execute("PRAGMA query_only=ON", database)
            try execute("BEGIN", database)
            let result = try snapshot(database)
            try execute("COMMIT", database)
            return result
        } catch Failure.malformed(let reason) {
            return ShellNotificationsData(
                state: "malformed",
                complete: false,
                issues: [.init(scope: .membership, reason: reason)],
                error: "Notification storage contains malformed data"
            )
        } catch {
            return ShellNotificationsData(
                state: "queryError",
                complete: false,
                error: "Unable to read notification storage"
            )
        }
    }

    private static func snapshot(_ database: OpaquePointer) throws -> ShellNotificationsData {
        var budget = Budget()
        let source = try tables(database, budget: &budget)
        var result = Collected()
        for app in source
            .apps { try collectApp(app, from: source, database: database, budget: &budget, result: &result) }
        return finish(result, memberships: source.memberships, budget: &budget)
    }

    private static func tables(_ database: OpaquePointer, budget: inout Budget) throws -> Tables {
        let delivered = try rows("SELECT app_id,list FROM delivered", database, &budget)
        var memberships: [Int64: Set<String>] = [:]
        for row in delivered {
            guard let app = row["app_id"]?.integer else { throw Failure.malformed(.invalidMembership) }
            do { memberships[app] = try membership(row["list"]) }
            catch { budget.mark(.invalidMembership) }
        }
        let activeApps = memberships.filter { !$0.value.isEmpty }.keys.sorted().map(String.init).joined(separator: ",")
        let appMembers = activeApps.isEmpty ? [] : try rows(
            "SELECT app_id,identifier FROM app WHERE app_id IN (\(activeApps)) ORDER BY app_id", database, &budget
        )
        let appMetadata = try rows("SELECT * FROM app ORDER BY app_id", database, &budget, scope: .metadata)
        let apps = mergeApps(appMembers, metadata: appMetadata)
        let categories = try rows("SELECT * FROM categories", database, &budget, scope: .metadata)
        var lists: [String: [[String: Column]]] = [:]
        for table in ["delivered", "displayed", "requests"] {
            lists[table] = try rows("SELECT * FROM \(table)", database, &budget, scope: .metadata)
        }
        let records = activeApps.isEmpty ? [] : try recordRows(
            "SELECT * FROM record WHERE app_id IN (\(activeApps))", database, &budget, retained: memberships
        )
        return Tables(apps: apps, categories: categories, lists: lists, memberships: memberships, records: records)
    }

    private struct RecordKey: Hashable {
        let appID: Int64
        let uuid: Data
        let payload: Data

        init?(_ row: [String: Column]) {
            guard let appID = row["app_id"]?.integer, let uuid = row["uuid"]?.blob,
                  let payload = row["data"]?.blob else { return nil }
            self.appID = appID
            self.uuid = uuid
            self.payload = payload
        }
    }

    private static func recordRows(
        _ sql: String, _ database: OpaquePointer, _ budget: inout Budget,
        retained: [Int64: Set<String>]? = nil
    ) throws -> [[String: Column]] {
        let core = sql.replacingOccurrences(of: "SELECT *", with: "SELECT app_id,uuid,data")
        let members = try rows(core, database, &budget, retained: retained)
        let metadata = try rows(sql, database, &budget, scope: .metadata, retained: retained)
        var byRecord: [RecordKey: [String: Column]] = [:]
        for row in metadata {
            if let key = RecordKey(row) { byRecord[key] = row }
        }
        return members.map { row in
            guard let key = RecordKey(row) else { return row }
            return (byRecord[key] ?? [:]).merging(row) { _, member in member }
        }
    }

    private static func mergeApps(
        _ members: [[String: Column]], metadata: [[String: Column]]
    ) -> [[String: Column]] {
        var merged: [Int64: [String: Column]] = [:]
        for row in metadata {
            if let id = row["app_id"]?.integer { merged[id] = row }
        }
        for row in members {
            if let id = row["app_id"]?.integer { merged[id] = (merged[id] ?? [:]).merging(row) { _, member in member } }
        }
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    private static func collectApp(
        _ app: [String: Column],
        from tables: Tables,
        database: OpaquePointer,
        budget: inout Budget,
        result: inout Collected
    ) throws {
        guard let appID = app["app_id"]?.integer else { throw Failure.malformed(.invalidApp) }
        guard let bundle = app["identifier"]?.text, ShellNotificationsCommand.validBundle(bundle) else {
            budget.mark(.invalidApp, scope: tables.memberships[appID]?.isEmpty == false ? .membership : .metadata)
            return
        }
        let decoded = category(tables.categories.first { $0["app_id"]?.integer == appID }, budget: &budget)
        result.apps.append(appMetadata(app, bundle: bundle, categories: decoded, lists: tables.lists, budget: &budget))
        guard let retained = tables.memberships[appID], !retained.isEmpty else { return }
        let context = RecordContext(appID: appID, bundle: bundle, retained: retained, categories: decoded.categories)
        collect(
            tables.records.filter { $0["app_id"]?.integer == appID },
            context: context,
            budget: &budget,
            result: &result
        )
        guard !(result.found[appID] ?? []).isSuperset(of: retained) else { return }
        let fallback = try recordRows("SELECT * FROM record WHERE app_id=\(appID)", database, &budget)
        let candidates = fallback.filter { row in
            guard let bytes = row["uuid"]?.blob, let id = ShellNotificationMetadata.guid(bytes) else { return false }
            return !retained.contains(id)
        }
        collect(candidates, context: context, budget: &budget, result: &result, tolerateNonmemberFailure: true)
    }

    private static func finish(
        _ collected: Collected,
        memberships: [Int64: Set<String>],
        budget: inout Budget
    ) -> ShellNotificationsData {
        for (app, retained) in memberships
            where !(collected.found[app] ?? []).isSuperset(of: retained) { budget.mark(.missingRecord) }
        var items = collected.items.sorted {
            let lhs = $0.fields?["date"]?.number ?? 0
            let rhs = $1.fields?["date"]?.number ?? 0
            return lhs == rhs ? ($0.fields?["id"]?.string ?? "") < ($1.fields?["id"]?.string ?? "") : lhs > rhs
        }
        var identifiers = Set<String>()
        items = items.filter {
            guard let id = $0.fields?["id"]?.string, identifiers.insert(id).inserted else {
                budget.mark(.duplicateIdentifier)
                return false
            }
            return true
        }
        if items.count > 256 { items = Array(items.prefix(256))
            budget.mark(.notificationLimit)
        }
        items = budget.packMembers(items)
        let apps = collected.apps.filter { budget.includeMetadata($0) }
        let state = budget
            .complete ? (items.isEmpty ? "empty" : "ready") : (budget.malformed ? "malformed" : "incomplete")
        return ShellNotificationsData(
            state: state,
            items: items,
            apps: apps,
            complete: budget.complete,
            membershipComplete: budget.membershipComplete,
            metadataComplete: budget.metadataComplete,
            issues: Array(budget.issues),
            error: budget.complete ? nil : "Notification snapshot incomplete"
        )
    }

    private static func collect(
        _ records: [[String: Column]],
        context: RecordContext,
        budget: inout Budget,
        result: inout Collected,
        tolerateNonmemberFailure: Bool = false
    ) {
        for row in records {
            do {
                guard let item = try record(
                    row,
                    bundle: context.bundle,
                    retained: context.retained,
                    categories: context.categories,
                    budget: &budget
                ), let id = item.fields?["id"]?.string else { continue }
                if result.found[context.appID, default: []].insert(id).inserted { result.items.append(item) }
                else { budget.mark(.duplicateIdentifier) }
            } catch {
                if tolerateNonmemberFailure { continue }
                budget.mark((error as? ShellNotificationMetadata.Failure) == .limit ? .decodeLimit : .invalidRecord)
            }
        }
    }
}

extension ShellNotificationStore {
    private static func category(
        _ row: [String: Column]?,
        budget: inout Budget
    ) -> (categories: ShellServiceValue, metadata: ShellServiceValue) {
        guard let bytes = row?["categories"]?.blob else { return (.array([]), row.map(columns) ?? .null) }
        do {
            let decoded = try ShellNotificationMetadata.decode(bytes)
            if !decoded.complete { budget.mark(.invalidMetadata, scope: .metadata) }
            return (
                decoded.resolved,
                .object([
                    "raw": ShellNotificationMetadata.opaque(bytes),
                    "payload": decoded.value,
                    "resolved": decoded.resolved,
                    "columns": row.map(columns) ?? .null
                ])
            )
        } catch {
            budget.mark(
                (error as? ShellNotificationMetadata.Failure) == .limit ? .decodeLimit : .invalidMetadata,
                scope: .metadata
            )
            return (
                .array([]),
                .object([
                    "raw": ShellNotificationMetadata.opaque(bytes),
                    "decodeState": .text("incomplete"),
                    "columns": row.map(columns) ?? .null
                ])
            )
        }
    }

    private static func appMetadata(
        _ app: [String: Column],
        bundle: String,
        categories: (categories: ShellServiceValue, metadata: ShellServiceValue),
        lists: [String: [[String: Column]]],
        budget: inout Budget
    ) -> ShellServiceValue {
        var fields: [String: ShellServiceValue] = [
            "bundle": .text(bundle),
            "columns": columns(app),
            "categories": categories.categories,
            "categoryMetadata": categories.metadata
        ]
        for table in ["delivered", "displayed", "requests"] {
            guard let row = lists[table]?.first(where: { $0["app_id"]?.integer == app["app_id"]?.integer })
            else { fields[table] = .null
                continue
            }
            do { fields[table] = .object([
                "columns": columns(row),
                "ids": .array(try membership(row["list"]).sorted().map(ShellServiceValue.text))
            ]) } catch {
                fields[table] = .object(["columns": columns(row), "ids": .null])
                budget.mark(.invalidMembership, scope: .metadata)
            }
        }
        return .object(fields)
    }

    private static func record(
        _ row: [String: Column],
        bundle: String,
        retained: Set<String>,
        categories: ShellServiceValue,
        budget: inout Budget
    ) throws -> ShellServiceValue? {
        guard let bytes = row["data"]?.blob else { throw Failure.malformed(.invalidRecord) }
        guard let identity = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any],
              let guidBytes = identity["uuid"] as? Data,
              let guid = ShellNotificationMetadata.guid(guidBytes) else { throw Failure.malformed(.invalidRecord) }
        guard retained.contains(guid) else { return nil }
        if row["uuid"]?.blob != guidBytes { budget.mark(.identifierMismatch) }
        let decoded = decodeMetadata(bytes, budget: &budget)
        let root = decoded?.value.fields ?? [:]
        if decoded != nil, root["req"]?.fields == nil { budget.mark(.invalidMetadata, scope: .metadata) }
        let request = root["req"]?.fields ?? [:]
        let category = request["cate"]?.string ?? ""
        let definition = categories.values?.first { $0.fields?["id"]?.string == category }
        let date = root["date"]?.number.map { $0 + Date.timeIntervalBetween1970AndReferenceDate }
        return .object([
            "id": .text(guid), "bundle": .text(bundle), "title": text(request["titl"], budget: &budget),
            "subtitle": text(request["subt"], budget: &budget), "body": text(request["body"], budget: &budget),
            "date": date.map(ShellServiceValue.number) ?? .null,
            "requestId": request["iden"] ?? .null, "thread": request["thre"] ?? .null, "category": .text(category),
            "attachments": .array(attachments(request)), "actions": .array(actions(definition)),
            "userInfo": ShellNotificationMetadata.unwrapped(request["usda"]),
            "communication": ShellNotificationMetadata.unwrapped(request["uncc"]),
            "metadata": .object([
                "rawPayload": ShellNotificationMetadata.opaque(bytes),
                "payload": decoded?.value ?? .null,
                "columns": columns(row)
            ])
        ])
    }

    private static func decodeMetadata(_ bytes: Data, budget: inout Budget) -> ShellNotificationMetadata.Decoded? {
        do {
            let decoded = try ShellNotificationMetadata.decode(bytes)
            if !decoded.complete { budget.mark(.invalidMetadata, scope: .metadata) }
            return decoded
        } catch {
            budget.mark(
                (error as? ShellNotificationMetadata.Failure) == .limit ? .decodeLimit : .invalidMetadata,
                scope: .metadata
            )
            return nil
        }
    }

    private static func text(_ value: ShellServiceValue?, budget: inout Budget) -> ShellServiceValue {
        guard let value else { return .text("") }
        if value.string != nil { return value }
        budget.mark(.unsupportedText, scope: .metadata)
        return .text("")
    }

    private static func attachments(_ request: [String: ShellServiceValue]) -> [ShellServiceValue] {
        request["atta"]?.values?.map { value in
            let fields = value.fields ?? [:]
            let path = fields["pat"]?.string ?? ""
            return .object([
                "id": fields["id"] ?? .null,
                "type": fields["uti"] ?? .null,
                "path": .text(path),
                "available": .bool(!path.isEmpty && FileManager.default.fileExists(atPath: path)),
                "metadata": value
            ])
        } ?? []
    }

    private static func actions(_ definition: ShellServiceValue?) -> [ShellServiceValue] {
        (definition?.fields?["acts"]?.values ?? []).map { value in
            let fields = value.fields ?? [:]
            var result: [String: ShellServiceValue] = [
                "id": fields["id"] ?? .null,
                "title": fields["ti"] ?? .null,
                "options": fields["op"] ?? .number(0),
                "metadata": value
            ]
            if let value = fields["tia"] { result["textInputButtonTitle"] = value }
            if let value = fields["tip"] { result["textInputPlaceholder"] = value }
            return .object(result)
        }
    }

    private static func columns(_ row: [String: Column]) -> ShellServiceValue {
        .object(row.mapValues(\.value))
    }

    private static func membership(_ column: Column?) throws -> Set<String> {
        guard let column else { throw Failure.malformed(.invalidMembership) }
        if case .null = column { return [] }
        guard let bytes = column.blob,
              bytes.count.isMultiple(of: 16) else { throw Failure.malformed(.invalidMembership) }
        var values = Set<String>()
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            guard let guid = ShellNotificationMetadata.guid(bytes.subdata(in: offset ..< offset + 16))
            else { throw Failure.malformed(.invalidMembership) }
            values.insert(guid)
        }
        return values
    }

    private static func execute(_ sql: String, _ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.query }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.query }
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import SQLite3

extension ShellNotificationStore {
    enum Column {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var value: ShellServiceValue {
            switch self {
            case .null: .null
            case let .integer(value): ShellNotificationMetadata.integer(value)
            case let .real(value): .number(value)
            case let .text(value): .text(value)
            case let .blob(value): ShellNotificationMetadata.opaque(value)
            }
        }

        var integer: Int64? {
            if case let .integer(value) = self { value } else { nil }
        }

        var text: String? {
            if case let .text(value) = self { value } else { nil }
        }

        var blob: Data? {
            if case let .blob(value) = self { value } else { nil }
        }
    }

    static func rows(
        _ sql: String,
        _ database: OpaquePointer,
        _ budget: inout ShellNotificationReadBudget,
        scope: ShellNotificationReadIssue.Scope = .membership,
        retained: [Int64: Set<String>]? = nil
    ) throws -> [[String: Column]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.query }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Column]] = []
        let names = (0 ..< sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Failure.query }
            guard budget.acceptRow(scope: scope) else { return result }
            if skip(statement, names: names, retained: retained) { continue }
            do {
                if let row = try row(statement, names: names, budget: &budget, scope: scope) { result.append(row) }
            } catch {
                guard scope == .metadata else { throw error }
                budget.mark(.invalidMetadata, scope: .metadata)
            }
        }
    }

    private static func skip(_ statement: OpaquePointer, names: [String], retained: [Int64: Set<String>]?) -> Bool {
        guard let retained, let appIndex = names.firstIndex(of: "app_id"),
              let uuidIndex = names.firstIndex(of: "uuid") else { return false }
        let index = Int32(uuidIndex)
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB, sqlite3_column_bytes(statement, index) == 16,
              let pointer = sqlite3_column_blob(
                  statement,
                  index
              ), let guid = ShellNotificationMetadata.guid(Data(bytes: pointer, count: 16)) else { return false }
        return !(retained[sqlite3_column_int64(statement, Int32(appIndex))] ?? []).contains(guid)
    }

    private static func row(
        _ statement: OpaquePointer,
        names: [String],
        budget: inout ShellNotificationReadBudget,
        scope: ShellNotificationReadIssue.Scope
    ) throws -> [String: Column]? {
        var row: [String: Column] = [:]
        var accepted = true
        for (index, name) in names.enumerated() {
            if let value = try column(statement, index: Int32(index), budget: &budget, scope: scope) {
                row[name] = value
            } else { accepted = false }
        }
        return accepted ? row : nil
    }

    private static func column(
        _ statement: OpaquePointer, index: Int32, budget: inout ShellNotificationReadBudget,
        scope: ShellNotificationReadIssue.Scope
    ) throws -> Column? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, index)
            guard value.isFinite else { throw Failure.malformed(.invalidRecord) }
            return .real(value)
        default:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard budget.acceptBytes(count, scope: scope) else { return nil }
            if sqlite3_column_type(statement, index) == SQLITE_TEXT {
                guard let value = sqlite3_column_text(statement, index), let text = String(
                    data: Data(bytes: value, count: count),
                    encoding: .utf8
                ) else { throw Failure.malformed(.invalidRecord) }
                return .text(text)
            }
            let pointer = sqlite3_column_blob(statement, index)
            guard count == 0 || pointer != nil else { throw Failure.malformed(.invalidRecord) }
            return .blob(pointer.map { Data(bytes: $0, count: count) } ?? Data())
        }
    }
}

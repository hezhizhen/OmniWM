// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import SQLite3
import XCTest

@MainActor
final class ShellNotificationCompletenessTests: XCTestCase {
    private let bundle = "com.example.NotificationCompleteness"

    func testUnusedAppMetadataLimitDoesNotDisableDismissal() async throws {
        let value = try snapshot(metadataBytes: 800_000)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        try await assertDismissals(value)
    }

    func testUnsupportedTitleDoesNotDisableDismissal() async throws {
        let value = try snapshot(unsupportedTitle: true)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        try await assertDismissals(value)
    }

    func testDeepOptionalMetadataDoesNotHideKnownMembers() async throws {
        let value = try snapshot(deepUserInfo: true)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .decodeLimit)))
        try await assertDismissals(value)
    }

    func testMissingRequestDetailsDoNotDisableKnownMembers() async throws {
        let value = try snapshot(missingRequest: true)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .invalidMetadata)))
        try await assertDismissals(value)
    }

    func testOptionalReadBudgetCannotConsumeMembershipBudget() async throws {
        let value = try snapshot(metadataBytes: 1_500_000, metadataApps: 4)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .byteLimit)))
        try await assertDismissals(value)
    }

    func testSnapshotBudgetPreservesAllMemberIdentitiesBeforeOptionalPayloads() async throws {
        let value = try snapshot(payloadBytes: 600_000)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .encodingLimit)))
        var writer = ShellValueWriter()
        value.write(into: &writer)
        XCTAssertLessThan(writer.bytes.count, 4 << 20)
        try await assertDismissals(value)
    }

    func testFlagsAndSpecificIssuesReachTheWidgetAndDiagnostics() async throws {
        let value = try snapshot(unsupportedTitle: true)
        var writer = ShellValueWriter()
        value.write(into: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded.fields?["complete"], .bool(false))
        XCTAssertEqual(decoded.fields?["membershipComplete"], .bool(true))
        XCTAssertEqual(decoded.fields?["metadataComplete"], .bool(false))
        XCTAssertEqual(decoded.fields?["issues"]?.values, [
            .object(["scope": .text("metadata"), "reason": .text("unsupportedText")])
        ])
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Some notification text uses an unsupported format.", []
        )))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.diagnosticsSummary.contains("membershipComplete=true metadataComplete=false"))
        XCTAssertTrue(controller.diagnosticsSummary.contains("issues=metadata:unsupportedText"))
    }

    func testIdentifierMismatchAndDuplicateMembersRemainBlocked() async throws {
        for value in [try snapshot(mismatchedIdentifier: true), try snapshot(duplicateMember: true)] {
            XCTAssertFalse(value.membershipComplete)
            let controller = await controller(value)
            defer { controller.setListening(false) }
            XCTAssertFalse(controller.perform(.dismissAll))
            XCTAssertFalse(try widgetCommands(value).contains("notifications dismiss-all"))
        }
        XCTAssertTrue(try snapshot(mismatchedIdentifier: true).issues.contains(
            .init(scope: .membership, reason: .identifierMismatch)
        ))
        XCTAssertTrue(try snapshot(duplicateMember: true).issues.contains(
            .init(scope: .membership, reason: .duplicateIdentifier)
        ))
    }

    func testMetadataOnlyIncompletenessDoesNotEnableReplies() async throws {
        var target = try XCTUnwrap(snapshot(unsupportedTitle: true).items.first?.fields)
        target["actions"] = .array([.object([
            "title": .text("Reply"), "textInputButtonTitle": .text("Send")
        ])])
        let value = ShellNotificationsData(
            state: "incomplete", items: [.object(target)], complete: false,
            membershipComplete: true, metadataComplete: false
        )
        let controller = await controller(value)
        defer { controller.setListening(false) }
        let id = try XCTUnwrap(target["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(controller.perform(.reply(bundle: bundle, id: id, text: "Test reply")))
        XCTAssertNil(controller.actionTask)
    }

    func testPendingActionOnAnotherPageHasAVisibleGlobalReason() throws {
        let items = (1 ... 9).map { index in
            ShellServiceValue.object([
                "id": .text("fixture-\(index)"), "bundle": .text(bundle), "title": .text("Fixture title"),
                "body": .text("Fixture body")
            ])
        }
        let value = ShellNotificationsData(state: "ready", items: items, action: .object([
            "id": .text("fixture-9"), "bundle": .text(bundle), "kind": .text("dismiss"), "state": .text("pending")
        ]))
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        let tree = widget.renderPopout()
        XCTAssertFalse(tree.contains { widget.text.string($0.content.action) == "notifications dismiss-all" })
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Another notification action is still in progress.", []
        )))
    }

    func testMissingMemberStillDisablesDismissal() async throws {
        let value = try snapshot(missingMember: true)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        let controller = await controller(value)
        defer { controller.setListening(false) }
        let id = try XCTUnwrap(value.items.first?.fields?["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: id)))
        XCTAssertFalse(controller.perform(.dismissAll))
        let commands = try widgetCommands(value)
        XCTAssertFalse(commands.contains("notifications dismiss-all"))
        XCTAssertFalse(commands.contains { $0.hasPrefix("notifications dismiss ") })
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .missingRecord)))
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Some retained notifications are missing from notification storage.", []
        )))
    }

    private func assertDismissals(_ value: ShellNotificationsData) async throws {
        var singles: [ShellNotificationActionRequest] = []
        let single = await controller(value, perform: { request in
            singles.append(request)
            return .dispatched
        })
        defer { single.setListening(false) }
        let id = try XCTUnwrap(value.items.first?.fields?["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(single.perform(.dismiss(bundle: bundle, id: id)))
        await single.actionTask?.value
        XCTAssertEqual(singles.map(\.id), [id])

        var batches: [[ShellNotificationActionRequest]] = []
        let batch = await controller(value, dismissAll: { requests, progress in
            batches.append(requests)
            for _ in requests { progress(.dispatched) }
            return .dispatched
        })
        defer { batch.setListening(false) }
        XCTAssertTrue(batch.perform(.dismissAll))
        await batch.actionTask?.value
        XCTAssertEqual(batches.first?.count, value.items.count)

        let commands = try widgetCommands(value)
        XCTAssertTrue(commands.contains("notifications dismiss-all"))
        XCTAssertEqual(commands.filter { $0.hasPrefix("notifications dismiss ") }.count, value.items.count)
    }

    private func controller(
        _ value: ShellNotificationsData,
        perform: ShellNotificationsController.ActionPerformer? = nil,
        dismissAll: ShellNotificationsController.DismissAllPerformer? = nil
    ) async -> ShellNotificationsController {
        let controller = ShellNotificationsController(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("uncreated/db"),
            load: { _ in value },
            perform: perform ?? { _ in .failed },
            dismissAll: dismissAll ?? { _, _ in .failed },
            resolveName: { _ in nil }
        )
        controller.setListening(true)
        await controller.task?.value
        return controller
    }

    private func widgetCommands(_ value: ShellNotificationsData) throws -> [String] {
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        return widget.renderPopout().map { widget.text.string($0.content.action) }
    }

    private func snapshot(
        metadataBytes: Int = 0,
        metadataApps: Int = 1,
        payloadBytes: Int = 0,
        deepUserInfo: Bool = false,
        missingRequest: Bool = false,
        unsupportedTitle: Bool = false,
        missingMember: Bool = false,
        mismatchedIdentifier: Bool = false,
        duplicateMember: Bool = false
    ) throws -> ShellNotificationsData {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        try sql("""
        CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT);
        CREATE TABLE categories(app_id INTEGER PRIMARY KEY,categories BLOB);
        CREATE TABLE delivered(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE displayed(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE requests(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE record(app_id INTEGER,uuid BLOB,data BLOB);
        INSERT INTO app VALUES(1,'\(bundle)');
        """, db)
        for index in 2 ... (metadataApps + 1) {
            try sql("INSERT INTO app VALUES(\(index),'com.example.UnusedNotificationApp\(index)')", db)
            if metadataBytes > 0 {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: [["id": "unused", "description": String(repeating: "x", count: metadataBytes)]],
                    format: .binary, options: 0
                )
                try sql("INSERT INTO categories VALUES(\(index),\(blob(data)))", db)
            }
        }
        var membership = Data()
        for index in 1 ... (missingMember ? 3 : 2) {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
            let bytes = withUnsafeBytes(of: id.uuid) { Data($0) }
            membership.append(bytes)
            guard index <= 2 else { continue }
            let title: Any = unsupportedTitle && index == 1 ? ["localized title", "argument"] : "Fixture title"
            var request: [String: Any] = ["titl": title, "body": "Fixture body"]
            if payloadBytes > 0 { request["usda"] = Data(repeating: 42, count: payloadBytes) }
            if deepUserInfo, index == 1 {
                var details: [String: Any] = ["leaf": "Synthetic details"]
                for _ in 0 ..< 80 { details = ["next": details] }
                request["usda"] = details
            }
            var payload: [String: Any] = ["uuid": bytes, "date": 0.0, "req": request]
            if missingRequest, index == 1 { payload.removeValue(forKey: "req") }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary, options: 0
            )
            let columnID = mismatchedIdentifier && index == 1 ? Data(repeating: 7, count: 16) : bytes
            try sql("INSERT INTO record(app_id,uuid,data) VALUES(1,\(blob(columnID)),\(blob(data)))", db)
            if duplicateMember, index == 1 {
                try sql("INSERT INTO delivered VALUES(2,\(blob(bytes)))", db)
                try sql("INSERT INTO record(app_id,uuid,data) VALUES(2,\(blob(bytes)),\(blob(data)))", db)
            }
        }
        try sql("INSERT INTO delivered VALUES(1,\(blob(membership)))", db)
        return ShellNotificationStore.read(at: url)
    }

    private func blob(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private func sql(_ statement: String, _ db: OpaquePointer) throws {
        let result = sqlite3_exec(db, statement, nil, nil, nil)
        guard result == SQLITE_OK
        else { throw NSError(domain: "ShellNotificationCompletenessTests", code: Int(result)) }
    }
}

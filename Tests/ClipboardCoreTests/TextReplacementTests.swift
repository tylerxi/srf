import Testing
import Foundation
import SQLite3
@testable import ClipboardCore

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class FixtureDatabase {
    let directory: URL
    let databaseURL: URL
    let manifestURL: URL
    private var handle: OpaquePointer?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("srf-text-replacement-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("TextReplacements.db")
        manifestURL = directory.appendingPathComponent("text-replacements.json")
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK else {
            throw FixtureError("open failed")
        }
        try exec("""
        CREATE TABLE Z_PRIMARYKEY (
            Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER
        );
        INSERT INTO Z_PRIMARYKEY VALUES (1, 'TextReplacementEntry', 0, 0);
        CREATE TABLE ZTEXTREPLACEMENTENTRY (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZNEEDSSAVETOCLOUD INTEGER, ZWASDELETED INTEGER, ZTIMESTAMP TIMESTAMP,
            ZPHRASE VARCHAR, ZSHORTCUT VARCHAR, ZUNIQUENAME VARCHAR,
            ZREMOTERECORDINFO BLOB
        );
        """)
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    var database: TextReplacementDatabase {
        TextReplacementDatabase(databaseURL: databaseURL, manifestURL: manifestURL)
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw FixtureError(detail)
        }
    }

    func insert(primaryKey: Int64, shortcut: String, phrase: String, uniqueName: String,
                option: Int64 = 1, deleted: Int64 = 0) throws {
        let statement = try prepare(
            "INSERT INTO ZTEXTREPLACEMENTENTRY " +
            "(Z_PK, Z_ENT, Z_OPT, ZNEEDSSAVETOCLOUD, ZWASDELETED, ZTIMESTAMP, ZPHRASE, ZSHORTCUT, ZUNIQUENAME, ZREMOTERECORDINFO) " +
            "VALUES (?, 1, ?, 0, ?, 0, ?, ?, ?, NULL)"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, primaryKey)
        sqlite3_bind_int64(statement, 2, option)
        sqlite3_bind_int64(statement, 3, deleted)
        bind(phrase, 4, statement)
        bind(shortcut, 5, statement)
        bind(uniqueName, 6, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError("insert failed") }
    }

    func setMaximum(_ value: Int64) throws {
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = \(value) WHERE Z_NAME = 'TextReplacementEntry'")
    }

    func int(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    func text(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    func phrase(_ shortcut: String) throws -> String? {
        try text("SELECT ZPHRASE FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = '\(shortcut)' AND ZWASDELETED = 0")
    }

    func uniqueName(_ shortcut: String) throws -> String? {
        try text("SELECT ZUNIQUENAME FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = '\(shortcut)' AND ZWASDELETED = 0")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureError("prepare failed")
        }
        return statement
    }

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

@Suite struct TextReplacementChunkerTests {
    @Test func splitsFourCharactersWithShortcuts() {
        let entries = TextReplacementChunker.entries(from: "你好世界再见朋友")
        #expect(entries == [
            TextReplacementEntry(shortcut: "ffa", phrase: "你好世界"),
            TextReplacementEntry(shortcut: "ffb", phrase: "再见朋友"),
        ])
    }

    @Test func countsSwiftCharactersNotScalars() {
        let entries = TextReplacementChunker.entries(from: "👨‍👩‍👧‍👦abcde")
        #expect(entries.count == 2)
        #expect(entries[0].phrase == "👨‍👩‍👧‍👦abc")
        #expect(entries[1].phrase == "de")
    }

    @Test func collapsesWhitespaceBeforeSplitting() {
        #expect(TextReplacementChunker.normalize("  一 \n 二\t三   ") == "一 二 三")
        #expect(TextReplacementChunker.entries(from: " \n\t ").isEmpty)
    }

    @Test func stopsAtTwentySixEntries() {
        let answer = String(repeating: "字", count: 110)
        let entries = TextReplacementChunker.entries(from: answer)
        #expect(entries.count == 26)
        #expect(entries.first?.shortcut == "ffa")
        #expect(entries.last?.shortcut == "ffz")
        #expect(entries.last?.phrase == "字字字字")
    }

    @Test func rejectsInvalidDatabaseEntries() throws {
        let fixture = try FixtureDatabase()
        #expect(throws: TextReplacementError.emptyAnswer) {
            try fixture.database.publish([])
        }
        #expect(throws: TextReplacementError.invalidEntry("invalid phrase")) {
            try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "toolong")])
        }
    }
}

@Suite struct TextReplacementDatabaseTests {
    @Test func publishesUpdatesDeletesAndLeavesOtherEntries() throws {
        let fixture = try FixtureDatabase()
        try fixture.insert(primaryKey: 1, shortcut: "msd", phrase: "手工词条", uniqueName: "OLD-MSD")
        try fixture.setMaximum(1)

        let first = try fixture.database.publish([
            TextReplacementEntry(shortcut: "ffa", phrase: "AAAA"),
            TextReplacementEntry(shortcut: "ffb", phrase: "BBBB"),
        ])
        #expect(first.managedShortcuts == ["ffa", "ffb"])
        #expect(try fixture.database.managedShortcuts() == ["ffa", "ffb"])
        #expect(try fixture.database.allEntries().map(\.shortcut) == ["msd", "ffa", "ffb"])
        #expect(try fixture.phrase("ffa") == "AAAA")
        #expect(try fixture.int("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'TextReplacementEntry'") == 3)
        #expect(try fixture.int("SELECT Z_ENT FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = 'ffa'") == 1)
        #expect(try fixture.int("SELECT ZNEEDSSAVETOCLOUD FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = 'ffa'") == 0)
        let firstUnique = try fixture.uniqueName("ffa")

        let second = try fixture.database.publish([
            TextReplacementEntry(shortcut: "ffa", phrase: "CCCC"),
            TextReplacementEntry(shortcut: "ffb", phrase: "DDDD"),
        ])
        #expect(second.previousManagedShortcuts == ["ffa", "ffb"])
        #expect(try fixture.uniqueName("ffa") == firstUnique)
        #expect(try fixture.phrase("ffa") == "CCCC")
        #expect(try fixture.int("SELECT Z_OPT FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = 'ffa'") == 2)
        #expect(try fixture.int("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'TextReplacementEntry'") == 3)

        let third = try fixture.database.publish([
            TextReplacementEntry(shortcut: "ffa", phrase: "EEEE"),
        ])
        #expect(third.previousManagedShortcuts == ["ffa", "ffb"])
        #expect(try fixture.int("SELECT COUNT(*) FROM ZTEXTREPLACEMENTENTRY WHERE ZSHORTCUT = 'ffb'") == 0)
        #expect(try fixture.phrase("msd") == "手工词条")

        let removed = try fixture.database.clear()
        #expect(removed == ["ffa"])
        #expect(try fixture.database.allEntries().map(\.shortcut) == ["msd"])
        #expect(try fixture.database.managedShortcuts().isEmpty)
        #expect(try fixture.phrase("msd") == "手工词条")
    }

    @Test func refusesUnmanagedShortcutInsteadOfOverwriting() throws {
        let fixture = try FixtureDatabase()
        try fixture.insert(primaryKey: 1, shortcut: "ffa", phrase: "手工FFFF", uniqueName: "MANUAL")
        try fixture.setMaximum(1)

        #expect(throws: TextReplacementError.shortcutConflict(["ffa"])) {
            try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "NEW!")])
        }
        #expect(try fixture.phrase("ffa") == "手工FFFF")
        #expect(try fixture.database.managedShortcuts().isEmpty)
    }

    @Test func refusesReplacedUniqueName() throws {
        let fixture = try FixtureDatabase()
        try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "AAAA")])
        let oldUnique = try fixture.uniqueName("ffa")
        try fixture.exec("DELETE FROM ZTEXTREPLACEMENTENTRY")
        try fixture.insert(primaryKey: 2, shortcut: "ffa", phrase: "手工", uniqueName: "DIFFERENT")
        try fixture.setMaximum(2)

        #expect(throws: TextReplacementError.shortcutConflict(["ffa"])) {
            try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "BBBB")])
        }
        #expect(try fixture.phrase("ffa") == "手工")
        #expect(try fixture.database.managedShortcuts() == ["ffa"])
        #expect(oldUnique != (try fixture.uniqueName("ffa")))
    }

    @Test func corruptManifestStopsBeforeWritingRows() throws {
        let fixture = try FixtureDatabase()
        try Data("{not json".utf8).write(to: fixture.manifestURL)
        #expect(throws: TextReplacementError.manifestCorrupt) {
            try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "AAAA")])
        }
        #expect(try fixture.phrase("ffa") == nil)
    }

    @Test func softDeletedRowsAreIgnored() throws {
        let fixture = try FixtureDatabase()
        try fixture.insert(primaryKey: 1, shortcut: "old", phrase: "隐藏", uniqueName: "OLD", deleted: 1)
        try fixture.setMaximum(1)
        #expect(try fixture.database.allEntries().isEmpty)
        try fixture.database.publish([TextReplacementEntry(shortcut: "ffa", phrase: "AAAA")])
        #expect(try fixture.database.allEntries().map(\.shortcut) == ["ffa"])
        #expect(try fixture.int("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'TextReplacementEntry'") == 2)
    }
}

@Suite struct TextReplacementPreferencesTests {
    @Test func mergeReplacesManagedAndPreservesOthers() {
        let existing = [
            TextReplacementPreferenceItem(replace: "msd", with: "旧词"),
            TextReplacementPreferenceItem(on: 0, replace: "ffa", with: "旧FFA"),
            TextReplacementPreferenceItem(replace: "custom", with: "保留"),
        ]
        let merged = TextReplacementPreferences.merge(
            existing: existing,
            all: [
                TextReplacementEntry(shortcut: "ffa", phrase: "新FFA"),
                TextReplacementEntry(shortcut: "ffb", phrase: "新FFB"),
            ],
            removing: ["ffz"]
        )
        #expect(merged.map(\.replace) == ["msd", "custom", "ffa", "ffb"])
        #expect(merged.map(\.with) == ["旧词", "保留", "新FFA", "新FFB"])
    }

    @Test func mergeRemovesOnlyNamedShortcuts() {
        let existing = [
            TextReplacementPreferenceItem(replace: "ffa", with: "A"),
            TextReplacementPreferenceItem(replace: "ffb", with: "B"),
        ]
        let merged = TextReplacementPreferences.merge(existing: existing, all: [], removing: ["ffa"])
        #expect(merged.map(\.replace) == ["ffb"])
    }
}

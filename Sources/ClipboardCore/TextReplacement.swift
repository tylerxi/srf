import CoreFoundation
import Foundation
import SQLite3

public struct TextReplacementEntry: Codable, Sendable, Equatable {
    public var shortcut: String
    public var phrase: String
    public init(shortcut: String, phrase: String) {
        self.shortcut = shortcut
        self.phrase = phrase
    }
}

public struct TextReplacementStatus: Codable, Sendable, Equatable {
    public var enabled = false
    public var access = "unknown"
    public var managedShortcuts: [String] = []
    public var lastError: String?
    public var lastUpdated: Date?
    public var refresh = "write_only"
    public init() {}
}

public enum TextReplacementError: Error, Sendable, Equatable {
    case permissionDenied
    case databaseMissing
    case schemaMismatch
    case databaseBusy
    case shortcutConflict([String])
    case manifestCorrupt
    case emptyAnswer
    case invalidEntry(String)
    case writeFailed(String)
    case preferencesWriteFailed

    public var code: String {
        switch self {
        case .permissionDenied: "text_replacement_permission_required"
        case .databaseMissing: "text_replacement_database_missing"
        case .schemaMismatch: "text_replacement_schema_mismatch"
        case .databaseBusy: "text_replacement_database_busy"
        case .shortcutConflict: "text_replacement_shortcut_conflict"
        case .manifestCorrupt: "text_replacement_manifest_corrupt"
        case .emptyAnswer: "text_replacement_empty_answer"
        case .invalidEntry: "text_replacement_invalid_entry"
        case .writeFailed: "text_replacement_write_failed"
        case .preferencesWriteFailed: "text_replacement_preferences_write_failed"
        }
    }
}

public enum TextReplacementChunker {
    public static let charactersPerEntry = 4
    public static let maximumEntries = 26

    /// Collapses every run of whitespace to one ASCII space and trims the ends.
    public static func normalize(_ answer: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in answer {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace && !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(character)
        }
        return result
    }

    public static func entries(from answer: String) -> [TextReplacementEntry] {
        let characters = Array(normalize(answer))
        guard !characters.isEmpty else { return [] }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var entries: [TextReplacementEntry] = []
        var offset = 0
        var index = 0
        while offset < characters.count && index < maximumEntries {
            let end = min(offset + charactersPerEntry, characters.count)
            entries.append(TextReplacementEntry(
                shortcut: "ff" + String(letters[index]),
                phrase: String(characters[offset..<end])
            ))
            offset = end
            index += 1
        }
        return entries
    }
}

public struct TextReplacementManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var shortcut: String
        public var uniqueName: String
        public init(shortcut: String, uniqueName: String) {
            self.shortcut = shortcut
            self.uniqueName = uniqueName
        }
    }

    public var version = 1
    public var entries: [Entry] = []
    public init() {}
}

public struct TextReplacementPublishResult: Sendable, Equatable {
    public var managedShortcuts: [String]
    public var previousManagedShortcuts: [String]
    public init(managedShortcuts: [String], previousManagedShortcuts: [String]) {
        self.managedShortcuts = managedShortcuts
        self.previousManagedShortcuts = previousManagedShortcuts
    }
}

private struct TextReplacementRow {
    var pk: Int64
    var shortcut: String
    var uniqueName: String
    var phrase: String
    var option: Int64
}

private final class TextReplacementConnection {
    let handle: OpaquePointer

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TextReplacementError.databaseMissing
        }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Self.error(result, handle: db)
        }
        handle = db
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let detail = message.map { String(cString: $0) } ?? errorText
            sqlite3_free(message)
            throw Self.error(result, handle: handle, detail: detail)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw Self.error(result, handle: handle)
        }
        return statement
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Self.error(result, handle: handle)
        }
    }

    var errorText: String {
        String(cString: sqlite3_errmsg(handle))
    }

    static func error(_ code: Int32, handle: OpaquePointer?, detail: String? = nil) -> TextReplacementError {
        let message = detail ?? handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)"
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .databaseBusy
        case SQLITE_CANTOPEN, SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH:
            return .permissionDenied
        default:
            return .writeFailed(message)
        }
    }
}

private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
}

public final class TextReplacementDatabase: @unchecked Sendable {
    public let databaseURL: URL
    public let manifestURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()

    public init(databaseURL: URL, manifestURL: URL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.manifestURL = manifestURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
    }

    public func probe() throws {
        let connection = try TextReplacementConnection(url: databaseURL)
        _ = try validateSchema(connection)
        try connection.exec("BEGIN IMMEDIATE")
        try connection.exec("ROLLBACK")
    }

    public func managedShortcuts() throws -> [String] {
        try loadManifest().entries.map(\.shortcut)
    }

    public func allEntries() throws -> [TextReplacementEntry] {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return [] }
        let connection = try TextReplacementConnection(url: databaseURL)
        _ = try validateSchema(connection)
        return try readRows(connection).map { TextReplacementEntry(shortcut: $0.shortcut, phrase: $0.phrase) }
    }

    public func publish(_ entries: [TextReplacementEntry]) throws -> TextReplacementPublishResult {
        let desired = try validateEntries(entries)
        let connection = try TextReplacementConnection(url: databaseURL)
        let schema = try validateSchema(connection)
        let oldManifest = try loadManifest()
        try connection.exec("BEGIN IMMEDIATE")
        let previous = oldManifest.entries.map(\.shortcut)
        do {
            let rows = try readRows(connection)
            var byShortcut: [String: [TextReplacementRow]] = [:]
            var byUnique: [String: TextReplacementRow] = [:]
            for row in rows {
                byShortcut[row.shortcut, default: []].append(row)
                byUnique[row.uniqueName] = row
            }

            var conflicts = Set<String>()
            for entry in desired {
                guard let candidates = byShortcut[entry.shortcut], !candidates.isEmpty else { continue }
                if candidates.count > 1 { conflicts.insert(entry.shortcut); continue }
                let owned = oldManifest.entries.contains {
                    $0.shortcut == entry.shortcut && $0.uniqueName == candidates[0].uniqueName
                }
                if !owned { conflicts.insert(entry.shortcut) }
            }
            for entry in oldManifest.entries {
                if let row = byUnique[entry.uniqueName], row.shortcut != entry.shortcut {
                    conflicts.insert(entry.shortcut)
                    conflicts.insert(row.shortcut)
                }
            }
            guard conflicts.isEmpty else { throw TextReplacementError.shortcutConflict(conflicts.sorted()) }

            let zMax = try primaryKeyMaximum(connection, name: "TextReplacementEntry")
            let maxPK = try maximumPrimaryKey(connection)
            var nextPK = max(zMax, maxPK) + 1
            var highestPK = maxPK
            var newManifest = TextReplacementManifest()
            let desiredShortcuts = Set(desired.map(\.shortcut))

            for entry in desired {
                if let candidates = byShortcut[entry.shortcut], candidates.count == 1,
                   oldManifest.entries.contains(where: {
                       $0.shortcut == entry.shortcut && $0.uniqueName == candidates[0].uniqueName
                   }) {
                    let row = candidates[0]
                    try update(row: row, phrase: entry.phrase, shortcut: entry.shortcut, connection: connection)
                    newManifest.entries.append(.init(shortcut: entry.shortcut, uniqueName: row.uniqueName))
                } else {
                    let uniqueName = UUID().uuidString
                    try insert(primaryKey: nextPK, entity: schema.entity, phrase: entry.phrase,
                               shortcut: entry.shortcut, uniqueName: uniqueName, connection: connection)
                    highestPK = nextPK
                    nextPK += 1
                    newManifest.entries.append(.init(shortcut: entry.shortcut, uniqueName: uniqueName))
                }
            }

            for entry in oldManifest.entries where !desiredShortcuts.contains(entry.shortcut) {
                guard let row = byUnique[entry.uniqueName] else { continue }
                guard row.shortcut == entry.shortcut else {
                    throw TextReplacementError.shortcutConflict([entry.shortcut, row.shortcut])
                }
                try delete(primaryKey: row.pk, connection: connection)
            }

            if highestPK > zMax {
                try setPrimaryKeyMaximum(highestPK, connection: connection, name: "TextReplacementEntry")
            }

            try writeManifest(newManifest)
            do {
                try connection.exec("COMMIT")
            } catch {
                try? writeManifest(oldManifest)
                throw error
            }
            return TextReplacementPublishResult(
                managedShortcuts: newManifest.entries.map(\.shortcut),
                previousManagedShortcuts: previous
            )
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func clear() throws -> [String] {
        let manifest = try loadManifest()
        guard !manifest.entries.isEmpty else { return [] }
        let previous = manifest.entries.map(\.shortcut)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            try writeManifest(TextReplacementManifest())
            return previous
        }
        let connection = try TextReplacementConnection(url: databaseURL)
        _ = try validateSchema(connection)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let rows = try readRows(connection)
            var byUnique: [String: TextReplacementRow] = [:]
            for row in rows { byUnique[row.uniqueName] = row }
            for entry in manifest.entries {
                guard let row = byUnique[entry.uniqueName] else { continue }
                guard row.shortcut == entry.shortcut else {
                    throw TextReplacementError.shortcutConflict([entry.shortcut, row.shortcut])
                }
                try delete(primaryKey: row.pk, connection: connection)
            }
            try writeManifest(TextReplacementManifest())
            do {
                try connection.exec("COMMIT")
            } catch {
                try? writeManifest(manifest)
                throw error
            }
            return previous
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    private struct Schema {
        var entity: Int64
        var maximum: Int64
    }

    private func validateSchema(_ connection: TextReplacementConnection) throws -> Schema {
        let statement = try connection.prepare("PRAGMA table_info(ZTEXTREPLACEMENTENTRY)")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while try connection.step(statement) {
            if let name = textColumn(statement, 1) { columns.insert(name) }
        }
        let required: Set<String> = [
            "Z_PK", "Z_ENT", "Z_OPT", "ZNEEDSSAVETOCLOUD", "ZWASDELETED",
            "ZTIMESTAMP", "ZPHRASE", "ZSHORTCUT", "ZUNIQUENAME", "ZREMOTERECORDINFO"
        ]
        guard required.isSubset(of: columns) else { throw TextReplacementError.schemaMismatch }

        let primary = try connection.prepare(
            "SELECT Z_ENT, COALESCE(Z_MAX, 0) FROM Z_PRIMARYKEY WHERE Z_NAME = 'TextReplacementEntry'"
        )
        defer { sqlite3_finalize(primary) }
        guard try connection.step(primary) else { throw TextReplacementError.schemaMismatch }
        let entity = sqlite3_column_int64(primary, 0)
        let maximum = sqlite3_column_int64(primary, 1)
        guard entity > 0, maximum >= 0 else { throw TextReplacementError.schemaMismatch }
        return Schema(entity: entity, maximum: maximum)
    }

    private func primaryKeyMaximum(_ connection: TextReplacementConnection, name: String) throws -> Int64 {
        let statement = try connection.prepare(
            "SELECT COALESCE(Z_MAX, 0) FROM Z_PRIMARYKEY WHERE Z_NAME = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(name, at: 1, to: statement)
        guard try connection.step(statement) else { throw TextReplacementError.schemaMismatch }
        return sqlite3_column_int64(statement, 0)
    }

    private func maximumPrimaryKey(_ connection: TextReplacementConnection) throws -> Int64 {
        let statement = try connection.prepare("SELECT COALESCE(MAX(Z_PK), 0) FROM ZTEXTREPLACEMENTENTRY")
        defer { sqlite3_finalize(statement) }
        guard try connection.step(statement) else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func readRows(_ connection: TextReplacementConnection) throws -> [TextReplacementRow] {
        let statement = try connection.prepare(
            "SELECT Z_PK, ZSHORTCUT, ZUNIQUENAME, ZPHRASE, COALESCE(Z_OPT, 0) " +
            "FROM ZTEXTREPLACEMENTENTRY WHERE COALESCE(ZWASDELETED, 0) = 0 ORDER BY Z_PK"
        )
        defer { sqlite3_finalize(statement) }
        var rows: [TextReplacementRow] = []
        while try connection.step(statement) {
            guard let shortcut = textColumn(statement, 1), !shortcut.isEmpty,
                  let uniqueName = textColumn(statement, 2), !uniqueName.isEmpty,
                  let phrase = textColumn(statement, 3) else { continue }
            rows.append(TextReplacementRow(
                pk: sqlite3_column_int64(statement, 0),
                shortcut: shortcut,
                uniqueName: uniqueName,
                phrase: phrase,
                option: sqlite3_column_int64(statement, 4)
            ))
        }
        return rows
    }

    private func insert(primaryKey: Int64, entity: Int64, phrase: String, shortcut: String,
                        uniqueName: String, connection: TextReplacementConnection) throws {
        let statement = try connection.prepare(
            "INSERT INTO ZTEXTREPLACEMENTENTRY " +
            "(Z_PK, Z_ENT, Z_OPT, ZNEEDSSAVETOCLOUD, ZWASDELETED, ZTIMESTAMP, ZPHRASE, ZSHORTCUT, ZUNIQUENAME, ZREMOTERECORDINFO) " +
            "VALUES (?, ?, 1, 0, 0, ?, ?, ?, ?, NULL)"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, primaryKey)
        sqlite3_bind_int64(statement, 2, entity)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSinceReferenceDate)
        bind(phrase, at: 4, to: statement)
        bind(shortcut, at: 5, to: statement)
        bind(uniqueName, at: 6, to: statement)
        guard try connection.step(statement) == false else { throw TextReplacementError.writeFailed("insert returned a row") }
    }

    private func update(row: TextReplacementRow, phrase: String, shortcut: String,
                        connection: TextReplacementConnection) throws {
        let statement = try connection.prepare(
            "UPDATE ZTEXTREPLACEMENTENTRY SET ZPHRASE = ?, ZSHORTCUT = ?, " +
            "Z_OPT = COALESCE(Z_OPT, 0) + 1, ZTIMESTAMP = ?, ZNEEDSSAVETOCLOUD = 0, ZWASDELETED = 0 " +
            "WHERE Z_PK = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(phrase, at: 1, to: statement)
        bind(shortcut, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSinceReferenceDate)
        sqlite3_bind_int64(statement, 4, row.pk)
        guard try connection.step(statement) == false else { throw TextReplacementError.writeFailed("update returned a row") }
    }

    private func delete(primaryKey: Int64, connection: TextReplacementConnection) throws {
        let statement = try connection.prepare("DELETE FROM ZTEXTREPLACEMENTENTRY WHERE Z_PK = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, primaryKey)
        guard try connection.step(statement) == false else { throw TextReplacementError.writeFailed("delete returned a row") }
    }

    private func setPrimaryKeyMaximum(_ value: Int64, connection: TextReplacementConnection, name: String) throws {
        let statement = try connection.prepare("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, value)
        bind(name, at: 2, to: statement)
        guard try connection.step(statement) == false else { throw TextReplacementError.writeFailed("primary key update returned a row") }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func validateEntries(_ entries: [TextReplacementEntry]) throws -> [TextReplacementEntry] {
        guard !entries.isEmpty else { throw TextReplacementError.emptyAnswer }
        guard entries.count <= TextReplacementChunker.maximumEntries else {
            throw TextReplacementError.invalidEntry("too many entries")
        }
        let allowed = Set((0..<TextReplacementChunker.maximumEntries).map { index in
            "ff" + String(UnicodeScalar(UInt8(97 + index)))
        })
        var seen = Set<String>()
        for entry in entries {
            guard allowed.contains(entry.shortcut), seen.insert(entry.shortcut).inserted else {
                throw TextReplacementError.invalidEntry("invalid or duplicate shortcut")
            }
            guard !entry.phrase.isEmpty,
                  entry.phrase.count <= TextReplacementChunker.charactersPerEntry,
                  !entry.phrase.contains(where: { $0.isNewline }) else {
                throw TextReplacementError.invalidEntry("invalid phrase")
            }
        }
        return entries
    }

    private func loadManifest() throws -> TextReplacementManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return TextReplacementManifest() }
        let data = try Data(contentsOf: manifestURL)
        let manifest: TextReplacementManifest
        do {
            manifest = try JSONDecoder().decode(TextReplacementManifest.self, from: data)
        } catch {
            throw TextReplacementError.manifestCorrupt
        }
        guard manifest.version == 1 else { throw TextReplacementError.manifestCorrupt }
        let allowed = Set((0..<TextReplacementChunker.maximumEntries).map { index in
            "ff" + String(UnicodeScalar(UInt8(97 + index)))
        })
        var shortcuts = Set<String>()
        var uniqueNames = Set<String>()
        for entry in manifest.entries {
            guard allowed.contains(entry.shortcut), !entry.uniqueName.isEmpty,
                  shortcuts.insert(entry.shortcut).inserted,
                  uniqueNames.insert(entry.uniqueName).inserted else {
                throw TextReplacementError.manifestCorrupt
            }
        }
        return manifest
    }

    private func writeManifest(_ manifest: TextReplacementManifest) throws {
        let directory = manifestURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }
}

public struct TextReplacementPreferenceItem: Codable, Sendable, Equatable {
    public var on: Int
    public var replace: String
    public var with: String
    public init(on: Int = 1, replace: String, with: String) {
        self.on = on
        self.replace = replace
        self.with = with
    }
}

public enum TextReplacementPreferences {
    public static let key = "NSUserDictionaryReplacementItems"

    public static func read() -> [TextReplacementPreferenceItem]? {
        guard let value = CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        guard let array = value as? NSArray else { return nil }
        return array.compactMap { item in
            guard let dictionary = item as? NSDictionary,
                  let replace = dictionary["replace"] as? String,
                  let with = dictionary["with"] as? String else { return nil }
            let on: Int
            if let number = dictionary["on"] as? NSNumber {
                on = number.intValue
            } else if let flag = dictionary["on"] as? Bool {
                on = flag ? 1 : 0
            } else {
                on = 1
            }
            return TextReplacementPreferenceItem(on: on, replace: replace, with: with)
        }
    }

    public static func merge(existing: [TextReplacementPreferenceItem],
                             all: [TextReplacementEntry],
                             removing: Set<String>) -> [TextReplacementPreferenceItem] {
        let owned = Set(all.map(\.shortcut)).union(removing)
        var result = existing.filter { !owned.contains($0.replace) }
        var seen = Set(result.map(\.replace))
        for entry in all where seen.insert(entry.shortcut).inserted {
            result.append(TextReplacementPreferenceItem(replace: entry.shortcut, with: entry.phrase))
        }
        return result
    }

    public static func sync(all: [TextReplacementEntry], removing: Set<String>) throws {
        let merged = merge(existing: read() ?? [], all: all, removing: removing)
        let value = merged.map { item in
            ["on": item.on, "replace": item.replace, "with": item.with] as [String: Any]
        } as NSArray
        CFPreferencesSetValue(
            key as CFString,
            value,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesAppSynchronize(kCFPreferencesAnyApplication) else {
            throw TextReplacementError.preferencesWriteFailed
        }
    }
}

public final class TextReplacementService: @unchecked Sendable {
    private let database: TextReplacementDatabase
    private let queue = DispatchQueue(label: "com.bear.silentclipboard.text-replacement", qos: .utility)
    private let lock = NSLock()
    private var enabled: Bool
    private var status = TextReplacementStatus()

    public init(databaseURL: URL, manifestURL: URL, enabled: Bool) {
        self.database = TextReplacementDatabase(databaseURL: databaseURL, manifestURL: manifestURL)
        self.enabled = enabled
        self.status.enabled = enabled
        if enabled {
            queue.async { [weak self] in self?.refreshNow() }
        } else {
            queue.async { [weak self] in self?.clearNow() }
        }
    }

    public func setEnabled(_ value: Bool) {
        lock.lock()
        let changed = enabled != value
        enabled = value
        status.enabled = value
        lock.unlock()
        guard changed else { return }
        if value {
            queue.async { [weak self] in self?.refreshNow() }
        } else {
            queue.async { [weak self] in self?.clearNow() }
        }
    }

    public func publish(answer: String) {
        queue.async { [weak self] in
            guard let self, self.isEnabled else { return }
            do {
                let entries = TextReplacementChunker.entries(from: answer)
                guard !entries.isEmpty else { throw TextReplacementError.emptyAnswer }
                let result = try self.database.publish(entries)
                let all = try self.database.allEntries()
                try TextReplacementPreferences.sync(
                    all: all,
                    removing: Set(result.previousManagedShortcuts + result.managedShortcuts)
                )
                self.recordSuccess(shortcuts: result.managedShortcuts)
            } catch {
                self.recordFailure(error)
            }
        }
    }

    public func clear() {
        queue.async { [weak self] in self?.clearNow() }
    }

    public func refresh() {
        queue.async { [weak self] in self?.refreshNow() }
    }

    public func snapshot() -> TextReplacementStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Waits briefly for queued database/manifest writes before the process exits.
    public func flush(timeout: TimeInterval = 1) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func clearNow() {
        do {
            let previous = try database.clear()
            guard !previous.isEmpty else {
                var current = snapshot()
                current.enabled = isEnabled
                current.access = "allowed"
                current.managedShortcuts = []
                current.lastError = nil
                current.lastUpdated = Date()
                setStatus(current)
                return
            }
            let all = try database.allEntries()
            try TextReplacementPreferences.sync(all: all, removing: Set(previous))
            var current = snapshot()
            current.enabled = isEnabled
            current.access = "allowed"
            current.managedShortcuts = []
            current.lastError = nil
            current.lastUpdated = Date()
            setStatus(current)
        } catch {
            recordFailure(error)
        }
    }

    private func refreshNow() {
        do {
            try database.probe()
            let shortcuts = try database.managedShortcuts()
            var current = snapshot()
            current.enabled = isEnabled
            current.access = "allowed"
            current.managedShortcuts = shortcuts
            current.lastError = nil
            current.lastUpdated = Date()
            setStatus(current)
        } catch {
            recordFailure(error)
        }
    }

    private func recordSuccess(shortcuts: [String]) {
        var current = snapshot()
        current.enabled = isEnabled
        current.access = "allowed"
        current.managedShortcuts = shortcuts
        current.lastError = nil
        current.lastUpdated = Date()
        setStatus(current)
    }

    private func recordFailure(_ error: Error) {
        var current = snapshot()
        current.enabled = isEnabled
        current.lastError = (error as? TextReplacementError)?.code ?? "text_replacement_failed"
        current.lastUpdated = Date()
        if let replacement = error as? TextReplacementError {
            switch replacement {
            case .permissionDenied:
                current.access = "permission_required"
            case .databaseMissing:
                current.access = "database_missing"
            default:
                break
            }
        }
        setStatus(current)
    }

    private func setStatus(_ value: TextReplacementStatus) {
        lock.lock()
        status = value
        lock.unlock()
    }
}

import ChatDomain
import Foundation
import GRDB

/// Schema migrations. Never edit a shipped migration; append a new one.
enum Schema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_chatSummary") { db in
            try db.create(table: ChatSummaryRecord.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull().indexed()
                table.column("lastReadAt", .datetime)
                table.column("snippet", .text)
                table.column("isArchived", .boolean).notNull().defaults(to: false)
            }
        }
        // Chats library (CHATS-01…05): Starred, Project membership and local title search.
        migrator.registerMigration("v2_chatLibrary") { db in
            try db.alter(table: ChatSummaryRecord.databaseTableName) { table in
                table.add(column: "isStarred", .boolean).notNull().defaults(to: false)
                table.add(column: "projectID", .text)
            }
            try db.create(virtualTable: ChatSummaryRecord.searchTableName, using: FTS5()) { table in
                table.synchronize(withTable: ChatSummaryRecord.databaseTableName)
                table.tokenizer = .unicode61(diacritics: .remove)
                table.column("title")
            }
        }
        return migrator
    }()
}

struct ChatSummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chatSummary"
    /// FTS5 index over `title`, kept in sync with `chatSummary` by triggers.
    static let searchTableName = "chatSummaryFTS"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let isArchived = Column(CodingKeys.isArchived)
        static let isStarred = Column(CodingKeys.isStarred)
    }

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastReadAt: Date?
    var snippet: String?
    var isArchived: Bool
    var isStarred: Bool
    var projectID: String?

    init(_ summary: ChatSummary) {
        id = summary.id
        title = summary.title
        createdAt = summary.createdAt
        updatedAt = summary.updatedAt
        lastReadAt = summary.lastReadAt
        snippet = summary.snippet
        isArchived = summary.isArchived
        isStarred = summary.isStarred
        projectID = summary.projectID
    }

    var domain: ChatSummary {
        ChatSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastReadAt: lastReadAt,
            snippet: snippet,
            isArchived: isArchived,
            isStarred: isStarred,
            projectID: projectID
        )
    }
}

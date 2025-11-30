import Foundation
import GRDB

/// Creates and configures the database migrator for SwiftUIQuery
public func createMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    
    #if DEBUG
    // In debug mode, wipe and recreate if schema changes
    // This is safe for a cache database
    migrator.eraseDatabaseOnSchemaChange = true
    #endif
    
    migrator.registerMigration("v1_createQueryCache") { db in
        try db.create(table: "query_cache") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("cacheKey", .text).notNull().unique()
            t.column("queryHash", .text).notNull()
            t.column("responseData", .blob).notNull()
            t.column("responseType", .text).notNull()
            t.column("tags", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("staleAt", .datetime)
            t.column("expiresAt", .datetime)
            t.column("etag", .text)
            t.column("isInvalidated", .boolean).notNull().defaults(to: false)
        }
        
        // Index for key lookups
        try db.create(index: "idx_cache_key", on: "query_cache", columns: ["cacheKey"])
        
        // Index for tag-based queries (used by invalidation)
        try db.create(index: "idx_cache_tags", on: "query_cache", columns: ["tags"])
        
        // Index for garbage collection
        try db.create(index: "idx_cache_expires", on: "query_cache", columns: ["expiresAt"])
        
        // Index for stale queries
        try db.create(
            index: "idx_cache_stale",
            on: "query_cache",
            columns: ["staleAt", "isInvalidated"]
        )
    }
    
    // Future migrations go here
    // migrator.registerMigration("v2_addSomeFeature") { db in ... }
    
    return migrator
}

// MARK: - Database Setup

/// Configuration for the persistent cache database
public struct CacheDatabaseConfiguration: Sendable {
    /// Path to the database file
    public let path: String
    
    /// Whether to use WAL mode (recommended for concurrent access)
    public let useWAL: Bool
    
    /// Maximum database size in bytes (for cache pressure management)
    public let maxSize: Int64?
    
    public init(
        path: String? = nil,
        useWAL: Bool = true,
        maxSize: Int64? = nil
    ) {
        if let path {
            self.path = path
        } else {
            // Default to app's caches directory
            let cacheDir = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first!
            self.path = cacheDir.appendingPathComponent("SwiftUIQuery.sqlite").path
        }
        self.useWAL = useWAL
        self.maxSize = maxSize
    }
    
    /// In-memory-style database (for testing)
    ///
    /// Uses a temporary on-disk path to avoid WAL limitations of SQLite's
    /// pure in-memory databases on some platforms.
    public static var inMemory: CacheDatabaseConfiguration {
        CacheDatabaseConfiguration(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftUIQuery-\(UUID().uuidString).sqlite")
                .path,
            useWAL: false
        )
    }
}

/// Creates and configures a database pool for the cache
public func createDatabasePool(configuration: CacheDatabaseConfiguration) throws -> DatabasePool {
    var config = Configuration()

    // Avoid WAL when explicitly disabled
    config.journalMode = configuration.useWAL ? .wal : .default

    // Performance optimizations for a cache database
    config.prepareDatabase { db in
        // Use WAL mode for better concurrent access
        if configuration.useWAL {
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        
        // Reasonable page size for typical cache entries
        try db.execute(sql: "PRAGMA page_size = 4096")
        
        // Keep some pages in memory
        try db.execute(sql: "PRAGMA cache_size = -2000") // 2MB
        
        // Synchronous = NORMAL is a good balance for cache
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        
        // Enable foreign keys if we add relations later
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    
    let dbPool = try DatabasePool(path: configuration.path, configuration: config)
    
    // Run migrations
    try createMigrator().migrate(dbPool)
    
    return dbPool
}

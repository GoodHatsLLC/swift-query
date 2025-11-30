import Foundation
import GRDB

/// Result of a cache lookup
public struct CacheResult<T: Sendable>: Sendable {
    public let data: T
    public let isStale: Bool
    public let updatedAt: Date
    
    public init(data: T, isStale: Bool, updatedAt: Date) {
        self.data = data
        self.isStale = isStale
        self.updatedAt = updatedAt
    }
}

/// Thread-safe cache manager backed by GRDB
public actor QueryCache {
    private let dbPool: DatabasePool
    private var memoryCache: [String: AnyCacheEntry] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: - Initialization
    
    public init(configuration: CacheDatabaseConfiguration = .init()) throws {
        self.dbPool = try createDatabasePool(configuration: configuration)
    }
    
    /// For testing with a pre-configured pool
    internal init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }
    
    // MARK: - Read Operations
    
    /// Get a cached value by key
    public func get<T: Codable & Sendable>(key: String, as type: T.Type) async throws -> CacheResult<T>? {
        // Check memory cache first
        if let entry = memoryCache[key] as? CacheEntry<T> {
            return CacheResult(
                data: entry.data,
                isStale: entry.isStale,
                updatedAt: entry.updatedAt
            )
        }
        
        // Fall back to persistent store
        return try await dbPool.read { [decoder] db in
            guard let record = try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > Date()
                )
                .fetchOne(db) else {
                return nil
            }
            
            let data = try decoder.decode(T.self, from: record.responseData)
            return CacheResult(
                data: data,
                isStale: record.isStale,
                updatedAt: record.updatedAt
            )
        }
    }
    
    /// Check if a key exists in cache
    public func exists(key: String) async throws -> Bool {
        if memoryCache[key] != nil { return true }
        
        return try await dbPool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > Date()
                )
                .fetchCount(db) > 0
        }
    }
    
    // MARK: - Write Operations
    
    /// Set a cached value
    public func set<T: Codable & Sendable>(
        key: String,
        data: T,
        tags: Set<QueryTag>,
        staleTime: Duration,
        cacheTime: Duration
    ) async throws {
        let now = Date()
        let responseData = try encoder.encode(data)
        let tagsJson = tags.jsonEncoded
        let staleAt = now.addingTimeInterval(staleTime.timeInterval)
        let expiresAt = now.addingTimeInterval(cacheTime.timeInterval)
        
        // Update memory cache
        memoryCache[key] = CacheEntry(
            data: data,
            tags: tags,
            updatedAt: now,
            staleAt: staleAt,
            expiresAt: expiresAt
        )
        
        // Persist to GRDB
        try await dbPool.write { db in
            // Use INSERT OR REPLACE for upsert behavior
            var record = QueryCacheEntry(
                cacheKey: key,
                queryHash: responseData.sha256Hash,
                responseData: responseData,
                responseType: String(describing: T.self),
                tags: tagsJson,
                createdAt: now,
                updatedAt: now,
                staleAt: staleAt,
                expiresAt: expiresAt,
                isInvalidated: false
            )
            
            // Check if exists for proper upsert
            if let existing = try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .fetchOne(db) {
                record.id = existing.id
                record.createdAt = existing.createdAt
            }
            
            try record.save(db)
        }
    }
    
    // MARK: - Invalidation
    
    /// Invalidate all entries matching a tag prefix
    public func invalidate(tag: QueryTag) async throws -> [String] {
        // Mark as stale in memory
        var invalidatedKeys: [String] = []
        for (key, entry) in memoryCache {
            if entry.tags.containsMatch(for: tag) {
                entry.markStale()
                invalidatedKeys.append(key)
            }
        }
        
        // Mark as stale in database
        try await dbPool.write { db in
            try QueryCacheEntry.invalidate(tag: tag, in: db)
        }
        
        // Also get keys from database that weren't in memory
        let dbKeys = try await dbPool.read { db in
            try QueryCacheEntry.keysMatching(tag: tag, in: db)
        }
        
        return Array(Set(invalidatedKeys + dbKeys))
    }
    
    /// Invalidate a specific key
    public func invalidate(key: String) async throws {
        memoryCache[key]?.markStale()
        
        try await dbPool.write { db in
            try QueryCacheEntry.markStale(key: key, in: db)
        }
    }
    
    /// Remove a specific key from cache entirely
    public func remove(key: String) async throws {
        memoryCache.removeValue(forKey: key)
        
        try await dbPool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .deleteAll(db)
        }
    }
    
    /// Clear all cache entries
    public func clear() async throws {
        memoryCache.removeAll()
        
        try await dbPool.write { db in
            try QueryCacheEntry.deleteAll(db)
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Remove expired entries from the cache
    public func collectGarbage() async throws -> Int {
        // Clear expired from memory cache
        let now = Date()
        memoryCache = memoryCache.filter { !$0.value.isExpired(at: now) }
        
        // Delete expired from database
        return try await dbPool.write { db in
            try QueryCacheEntry.deleteExpired(in: db)
        }
    }
    
    // MARK: - Observation
    
    /// Observe changes to a specific cache key
    public func observe(key: String) -> AsyncStream<QueryCacheEntry?> {
        AsyncStream { [dbPool] continuation in
            let observation = ValueObservation
                .tracking { db in
                    try QueryCacheEntry
                        .filter(QueryCacheEntry.Columns.cacheKey == key)
                        .fetchOne(db)
                }
                .removeDuplicates()
            
            let cancellable = observation.start(
                in: dbPool,
                onError: { _ in continuation.finish() },
                onChange: { entry in continuation.yield(entry) }
            )
            
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
    
    // MARK: - Stats
    
    /// Get cache statistics
    public func stats() async throws -> CacheStats {
        let (total, stale, expired) = try await dbPool.read { db -> (Int, Int, Int) in
            let total = try QueryCacheEntry.fetchCount(db)
            
            let stale = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.isInvalidated == true ||
                    (QueryCacheEntry.Columns.staleAt != nil &&
                     QueryCacheEntry.Columns.staleAt < Date())
                )
                .fetchCount(db)
            
            let expired = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.expiresAt != nil &&
                    QueryCacheEntry.Columns.expiresAt < Date()
                )
                .fetchCount(db)
            
            return (total, stale, expired)
        }
        
        return CacheStats(
            totalEntries: total,
            staleEntries: stale,
            expiredEntries: expired,
            memoryEntries: memoryCache.count
        )
    }
}

// MARK: - Supporting Types

/// Cache statistics
public struct CacheStats: Sendable {
    public let totalEntries: Int
    public let staleEntries: Int
    public let expiredEntries: Int
    public let memoryEntries: Int
}

/// Type-erased cache entry protocol
protocol AnyCacheEntry: AnyObject {
    var tags: Set<QueryTag> { get }
    func markStale()
    func isExpired(at date: Date) -> Bool
}

/// Typed in-memory cache entry
final class CacheEntry<T: Sendable>: AnyCacheEntry {
    let data: T
    let tags: Set<QueryTag>
    let updatedAt: Date
    private let staleAt: Date
    private let expiresAt: Date
    private var _isInvalidated = false
    
    init(data: T, tags: Set<QueryTag>, updatedAt: Date, staleAt: Date, expiresAt: Date) {
        self.data = data
        self.tags = tags
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
    }
    
    var isStale: Bool {
        _isInvalidated || staleAt < Date()
    }
    
    func markStale() {
        _isInvalidated = true
    }
    
    func isExpired(at date: Date) -> Bool {
        expiresAt < date
    }
}

// MARK: - Data Extensions

extension Data {
    var sha256Hash: String {
        // Simple hash using built-in Swift hashing
        // For production, consider using CryptoKit
        var hasher = Hasher()
        hasher.combine(self)
        return String(format: "%08x", hasher.finalize())
    }
}

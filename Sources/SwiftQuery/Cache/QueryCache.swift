import Foundation
#if canImport(CryptoKit)
import CryptoKit
private typealias PlatformSHA256 = CryptoKit.SHA256
#else
import Crypto
private typealias PlatformSHA256 = Crypto.SHA256
#endif
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
    private let clock: QueryClock
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Ensure deterministic encoding so payload hashing and observation deduplication
        // remain stable even for types that contain Dictionaries.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    
    // MARK: - Initialization
    
    public init(configuration: CacheDatabaseConfiguration = .init(), clock: QueryClock = .system) throws {
        self.dbPool = try createDatabasePool(configuration: configuration)
        self.clock = clock
    }
    
    /// For testing with a pre-configured pool
    internal init(dbPool: DatabasePool, clock: QueryClock = .system) {
        self.dbPool = dbPool
        self.clock = clock
    }
    
    // MARK: - Read Operations
    
    /// Get a cached value by key
    public func get<T: Codable & Sendable>(key: String, as type: T.Type) async throws -> CacheResult<T>? {
        let now = clock.now()

        // Check memory cache first
        if let entry = memoryCache[key] as? CacheEntry<T> {
            if entry.isExpired(at: now) {
                memoryCache.removeValue(forKey: key)
            } else {
            return CacheResult(
                data: entry.data,
                isStale: entry.isStale(at: now),
                updatedAt: entry.updatedAt
            )
            }
        }
        
        // Fall back to persistent store
        return try await dbPool.read { [decoder] db in
            guard let record = try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > now
                )
                .fetchOne(db) else {
                return nil
            }
            
            let data = try decoder.decode(T.self, from: record.responseData)
            return CacheResult(
                data: data,
                isStale: record.isStale(at: now),
                updatedAt: record.updatedAt
            )
        }
    }
    
    /// Check if a key exists in cache
    public func exists(key: String) async throws -> Bool {
        let now = clock.now()
        if let entry = memoryCache[key] {
            if entry.isExpired(at: now) {
                memoryCache.removeValue(forKey: key)
            } else {
                return true
            }
        }
        
        return try await dbPool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > now
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
        let now = clock.now()
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
        let now = clock.now()
        // Mark as stale in memory
        var invalidatedKeys: [String] = []
        for (key, entry) in memoryCache {
            if entry.tags.containsMatch(for: tag) {
                entry.markStale()
                invalidatedKeys.append(key)
            }
        }
        
        // Mark as stale in database
        _ = try await dbPool.write { db in
            try QueryCacheEntry.invalidate(tag: tag, in: db)
        }
        
        // Also get keys from database that weren't in memory
        let dbKeys = try await dbPool.read { db in
            try QueryCacheEntry.keysMatching(tag: tag, now: now, in: db)
        }
        
        return Array(Set(invalidatedKeys + dbKeys))
    }
    
    /// Invalidate a specific key
    public func invalidate(key: String) async throws {
        memoryCache[key]?.markStale()
        
      _ = try await dbPool.write { db in
            try QueryCacheEntry.markStale(key: key, in: db)
        }
    }
    
    /// Remove a specific key from cache entirely
    public func remove(key: String) async throws {
        memoryCache.removeValue(forKey: key)
        
      _ = try await dbPool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key)
                .deleteAll(db)
        }
    }
    
    /// Clear all cache entries
    public func clear() async throws {
        memoryCache.removeAll()
        
      _ = try await dbPool.write { db in
            try QueryCacheEntry.deleteAll(db)
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Remove expired entries from the cache
    public func collectGarbage() async throws -> Int {
        // Clear expired from memory cache
        let now = clock.now()
        memoryCache = memoryCache.filter { !$0.value.isExpired(at: now) }
        
        // Delete expired from database
        return try await dbPool.write { db in
            try QueryCacheEntry.deleteExpired(now: now, in: db)
        }
    }
    
    // MARK: - Observation

    /// Observe changes to a specific cache key
    ///
    /// Deduplicates by payload hash + invalidation state - timestamp changes don't trigger new observations.
    /// This prevents infinite observation loops when staleTime is .zero.
    /// Properly handles task cancellation to prevent memory leaks.
    public func observe(key: String) -> AsyncStream<QueryCacheEntry?> {
        AsyncStream { [dbPool] continuation in
            let observation = ValueObservation
                .tracking { db in
                    try QueryCacheEntry
                        .filter(QueryCacheEntry.Columns.cacheKey == key)
                        .fetchOne(db)
                }
                .removeDuplicates(by: { old, new in
                    // Deduplicate by payload identity + explicit invalidation state.
                    //
                    // Do NOT use computed `isStale` (it depends on `Date()` and can
                    // introduce time-based flakiness). We only want to notify when:
                    // - the payload hash changes, or
                    // - invalidation toggles (fresh <-> invalidated).
                    //
                    // This prevents loops: fetch → cache.set (new updatedAt) → observe → fetch...
                    old?.queryHash == new?.queryHash && old?.isInvalidated == new?.isInvalidated
                })

            let task = Task {
                let cancellable = await observation.start(
                    in: dbPool,
                    onError: { _ in continuation.finish() },
                    onChange: { entry in
                        // Check cancellation before yielding to allow prompt exit
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(entry)
                    }
                )

                await withCancellationOperation {
                    cancellable.cancel()
                    continuation.finish()  // Finish stream when cancelled
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Stats
    
    /// Get cache statistics
    public func stats() async throws -> CacheStats {
        let now = clock.now()
        let (total, stale, expired) = try await dbPool.read { db -> (Int, Int, Int) in
            let total = try QueryCacheEntry.fetchCount(db)
            
            let stale = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.isInvalidated == true ||
                    (QueryCacheEntry.Columns.staleAt != nil &&
                     QueryCacheEntry.Columns.staleAt < now)
                )
                .fetchCount(db)
            
            let expired = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.expiresAt != nil &&
                    QueryCacheEntry.Columns.expiresAt < now
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
    
    func isStale(at date: Date) -> Bool {
        _isInvalidated || staleAt < date
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
        let digest = PlatformSHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

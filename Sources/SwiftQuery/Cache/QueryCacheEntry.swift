import Foundation
import GRDB

/// GRDB record for cached query responses
public struct QueryCacheEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "query_cache"
    
    // MARK: - Properties
    
    public var id: Int64?
    
    /// Unique cache key (e.g., "user:123")
    public var cacheKey: String
    
    /// SHA256 hash of response data for integrity checks
    public var queryHash: String
    
    /// JSON-encoded response data
    public var responseData: Data
    
    /// Type name for debugging
    public var responseType: String
    
    /// JSON array of tag segments for prefix queries
    public var tags: String
    
    /// When the entry was first created
    public var createdAt: Date
    
    /// When the entry was last updated
    public var updatedAt: Date
    
    /// When the data becomes stale (triggers background refetch)
    public var staleAt: Date?
    
    /// When to garbage collect the entry
    public var expiresAt: Date?
    
    /// HTTP ETag for conditional requests
    public var etag: String?
    
    /// Whether manually invalidated
    public var isInvalidated: Bool
    
    // MARK: - Column Definitions
    
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let cacheKey = Column(CodingKeys.cacheKey)
        public static let queryHash = Column(CodingKeys.queryHash)
        public static let responseData = Column(CodingKeys.responseData)
        public static let responseType = Column(CodingKeys.responseType)
        public static let tags = Column(CodingKeys.tags)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let staleAt = Column(CodingKeys.staleAt)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let etag = Column(CodingKeys.etag)
        public static let isInvalidated = Column(CodingKeys.isInvalidated)
    }
    
    // MARK: - Lifecycle
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
    
    // MARK: - Computed Properties
    
    /// Whether the cached data is stale
    public var isStale: Bool {
        isInvalidated || (staleAt.map { $0 < Date() } ?? false)
    }
    
    /// Whether the entry should be garbage collected
    public var isExpired: Bool {
        expiresAt.map { $0 < Date() } ?? false
    }
    
    // MARK: - Initialization
    
    public init(
        id: Int64? = nil,
        cacheKey: String,
        queryHash: String,
        responseData: Data,
        responseType: String,
        tags: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        staleAt: Date? = nil,
        expiresAt: Date? = nil,
        etag: String? = nil,
        isInvalidated: Bool = false
    ) {
        self.id = id
        self.cacheKey = cacheKey
        self.queryHash = queryHash
        self.responseData = responseData
        self.responseType = responseType
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
        self.etag = etag
        self.isInvalidated = isInvalidated
    }
}

// MARK: - Tag-Based Queries

extension QueryCacheEntry {
    /// Find all entries matching a tag prefix (for hierarchical invalidation)
    ///
    /// Tags are stored as JSON arrays. We search for entries where the tag segments
    /// appear as a prefix in the stored tags array.
    public static func matching(tag: QueryTag, in db: Database) throws -> [QueryCacheEntry] {
        // Build a LIKE pattern for prefix matching
        // Tags stored as: ["users","123","posts"]
        // Pattern for ["users","123"]: %"users"%"123"%
        let pattern = tag.segments.map { "\"\($0)\"" }.joined(separator: "%")
        
        return try QueryCacheEntry
            .filter(Columns.tags.like("%\(pattern)%"))
            .filter(Columns.expiresAt == nil || Columns.expiresAt > Date())
            .fetchAll(db)
    }
    
    /// Get all cache keys matching a tag prefix
    public static func keysMatching(tag: QueryTag, in db: Database) throws -> [String] {
        let pattern = tag.segments.map { "\"\($0)\"" }.joined(separator: "%")
        
        return try QueryCacheEntry
            .select(Columns.cacheKey)
            .filter(Columns.tags.like("%\(pattern)%"))
            .filter(Columns.expiresAt == nil || Columns.expiresAt > Date())
            .fetchAll(db)
            .map(\.cacheKey)
    }
    
    /// Mark matching entries as invalidated
    @discardableResult
    public static func invalidate(tag: QueryTag, in db: Database) throws -> Int {
        let pattern = tag.segments.map { "\"\($0)\"" }.joined(separator: "%")
        
        return try QueryCacheEntry
            .filter(Columns.tags.like("%\(pattern)%"))
            .updateAll(db, Columns.isInvalidated.set(to: true))
    }
    
    /// Mark a specific entry as stale
    @discardableResult
    public static func markStale(key: String, in db: Database) throws -> Bool {
        try QueryCacheEntry
            .filter(Columns.cacheKey == key)
            .updateAll(db, Columns.isInvalidated.set(to: true)) > 0
    }
    
    /// Delete expired entries (garbage collection)
    @discardableResult
    public static func deleteExpired(in db: Database) throws -> Int {
        try QueryCacheEntry
            .filter(Columns.expiresAt != nil && Columns.expiresAt < Date())
            .deleteAll(db)
    }
}

// MARK: - Decoding Helpers

extension QueryCacheEntry {
    /// Decode the stored response data to a specific type
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: responseData)
    }
}

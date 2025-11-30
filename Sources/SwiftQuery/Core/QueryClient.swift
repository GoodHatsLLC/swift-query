import Foundation

/// Central coordinator for all query operations.
///
/// QueryClient manages:
/// - Cache access and invalidation
/// - Active query tracking
/// - Prefetching
/// - Global configuration
///
/// Access via the shared instance or inject via environment:
/// ```swift
/// @Environment(\.queryClient) var client
/// ```
@MainActor
public final class QueryClient: Sendable {
    // MARK: - Shared Instance
    
    /// Shared query client instance
    public static let shared = QueryClient()
    
    // MARK: - Properties
    
    /// The underlying cache
    public let cache: QueryCache
    
    /// Default options for queries
    public let defaultOptions: QueryOptions
    
    /// Track active queries for refetching on invalidation
    private var activeQueries: [String: AnyWeakQueryObserver] = [:]
    
    // MARK: - Initialization
    
    public init(
        cacheConfiguration: CacheDatabaseConfiguration = .init(),
        defaultOptions: QueryOptions = .default
    ) {
        do {
            self.cache = try QueryCache(configuration: cacheConfiguration)
        } catch {
            // Fall back to in-memory cache if persistent fails
            // This shouldn't happen in normal operation
            self.cache = try! QueryCache(configuration: .inMemory)
        }
        self.defaultOptions = defaultOptions
    }
    
    /// For testing with a specific cache
    internal init(cache: QueryCache, defaultOptions: QueryOptions = .default) {
        self.cache = cache
        self.defaultOptions = defaultOptions
    }
    
    // MARK: - Query API
    
    /// Fetch data for a query, using cache when fresh
    public func fetch<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws -> K.Response {
        let opts = options ?? defaultOptions
        
        // Check cache first
        if let cached = try await cache.get(key: key.cacheKey, as: K.Response.self) {
            if !cached.isStale {
                return cached.data
            }
            
            // Have stale data - return it but trigger background refresh
            Task {
                _ = try? await fetchAndCache(key: key, options: opts, fetcher: fetcher)
            }
            return cached.data
        }
        
        // No cache - fetch fresh
        return try await fetchAndCache(key: key, options: opts, fetcher: fetcher)
    }
    
    /// Create an observable query state for SwiftUI
    public func query<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) -> QueryObserver<K> {
        let observer = QueryObserver(
            key: key,
            fetcher: fetcher,
            cache: cache,
            options: options ?? defaultOptions
        )
        
        // Track for invalidation-triggered refetch
        activeQueries[key.cacheKey] = AnyWeakQueryObserver(observer)
        
        return observer
    }
    
    // MARK: - Invalidation API
    
    /// Invalidate all queries matching the tag prefix
    public func invalidate(tag: QueryTag) async {
        let invalidatedKeys = try? await cache.invalidate(tag: tag)
        
        // Trigger refetch for active queries
        for key in invalidatedKeys ?? [] {
            if let observer = activeQueries[key]?.observer {
                Task {
                    await observer.refetch()
                }
            }
        }
        
        // Clean up dead references
        cleanupActiveQueries()
    }
    
    /// Invalidate a specific query by key
    public func invalidate<K: QueryKey>(key: K) async {
        try? await cache.invalidate(key: key.cacheKey)
        
        if let observer = activeQueries[key.cacheKey]?.observer {
            Task {
                await observer.refetch()
            }
        }
    }
    
    // MARK: - Direct Cache Manipulation
    
    /// Set query data directly in cache
    public func setQueryData<K: QueryKey>(_ key: K, data: K.Response) async {
        try? await cache.set(
            key: key.cacheKey,
            data: data,
            tags: key.tags,
            staleTime: defaultOptions.staleTime,
            cacheTime: defaultOptions.cacheTime
        )
    }
    
    /// Get cached data for a query
    public func getQueryData<K: QueryKey>(_ key: K) async -> K.Response? {
        try? await cache.get(key: key.cacheKey, as: K.Response.self)?.data
    }
    
    /// Remove a query from cache
    public func removeQueryData<K: QueryKey>(_ key: K) async {
        try? await cache.remove(key: key.cacheKey)
    }
    
    // MARK: - Prefetching
    
    /// Prefetch a query in the background
    public func prefetch<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async {
        let opts = options ?? defaultOptions
        
        // Only prefetch if not already cached and fresh
        if let cached = try? await cache.get(key: key.cacheKey, as: K.Response.self),
           !cached.isStale {
            return
        }
        
        _ = try? await fetchAndCache(key: key, options: opts, fetcher: fetcher)
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached data
    public func clear() async {
        try? await cache.clear()
    }
    
    /// Run garbage collection
    public func collectGarbage() async {
        _ = try? await cache.collectGarbage()
        cleanupActiveQueries()
    }
    
    /// Get cache statistics
    public func stats() async -> CacheStats? {
        try? await cache.stats()
    }
    
    // MARK: - Private Helpers
    
    private func fetchAndCache<K: QueryKey>(
        key: K,
        options: QueryOptions,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws -> K.Response {
        let data = try await fetcher()
        
        try await cache.set(
            key: key.cacheKey,
            data: data,
            tags: key.tags,
            staleTime: options.staleTime,
            cacheTime: options.cacheTime
        )
        
        return data
    }
    
    private func cleanupActiveQueries() {
        activeQueries = activeQueries.filter { $0.value.observer != nil }
    }
}

// MARK: - Type-Erased Observer Wrapper

/// Weak wrapper for active query tracking
private final class AnyWeakQueryObserver: @unchecked Sendable {
    private weak var _observer: AnyObject?
    
    init<K: QueryKey>(_ observer: QueryObserver<K>) {
        self._observer = observer
    }
    
    var observer: (any QueryObserverProtocol)? {
        _observer as? any QueryObserverProtocol
    }
}

/// Protocol for type-erased query observer access
@MainActor
protocol QueryObserverProtocol: AnyObject {
    @discardableResult
    func refetch() async -> Any?
}

extension QueryObserver: QueryObserverProtocol {
    @discardableResult
    public func refetch() async -> Any? {
        await refetch() as K.Response?
    }
}

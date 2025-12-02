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

    /// Tracks invalidation chains to detect cycles
    public let invalidationTracker: InvalidationTracker

    /// Track active queries for refetching on invalidation
    private var activeQueries: [String: AnyWeakQueryObserver] = [:]

    // MARK: - Initialization

    public init(
        cacheConfiguration: CacheDatabaseConfiguration = .init(),
        defaultOptions: QueryOptions = .default,
        invalidationTracking: InvalidationTracker.Configuration = .default
    ) {
        do {
            self.cache = try QueryCache(configuration: cacheConfiguration)
        } catch {
            // Fall back to in-memory cache if persistent fails
            // This shouldn't happen in normal operation
            self.cache = try! QueryCache(configuration: .inMemory)
        }
        self.defaultOptions = defaultOptions
        self.invalidationTracker = InvalidationTracker(configuration: invalidationTracking)
    }

    /// For testing with a specific cache
    internal init(
        cache: QueryCache,
        defaultOptions: QueryOptions = .default,
        invalidationTracking: InvalidationTracker.Configuration = .default
    ) {
        self.cache = cache
        self.defaultOptions = defaultOptions
        self.invalidationTracker = InvalidationTracker(configuration: invalidationTracking)
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
            options: options ?? defaultOptions,
            client: self
        )

        // Track for invalidation-triggered refetch
        registerActiveObserver(observer, forKey: key.cacheKey)

        return observer
    }
    
    // MARK: - Invalidation API

    /// Invalidate all queries matching the tag prefix
    ///
    /// This method tracks the invalidation chain to detect cyclical dependencies.
    /// If a cycle is detected, behavior depends on the `InvalidationTracker.Configuration`:
    /// - With `throwOnCycle: true`, throws `InvalidationTracker.TrackerError.cycleDetected`
    /// - With `throwOnCycle: false` (default), logs a warning and skips the cyclic invalidation
    ///
    /// - Parameter tag: The tag to invalidate (invalidates all queries with matching tag prefix)
    /// - Parameter source: Optional source identifier for debugging (e.g., "CreatePostMutation")
    public func invalidate(tag: QueryTag, source: String? = nil) async {
        do {
            try await invalidationTracker.withInvalidation(tag: tag, source: source) {
                let invalidatedKeys = try? await cache.invalidate(tag: tag)

                // Trigger refetch for active queries
                for key in invalidatedKeys ?? [] {
                    if let observer = activeQueries[key]?.observer {
                        Task {
                            await observer.triggerRefetch()
                        }
                    }
                }

                // Clean up dead references
                cleanupActiveQueries()
            }
        } catch {
            // Cycle detected with throwOnCycle: true - the warning is already logged
            // In production, you might want to handle this differently
        }
    }

    /// Invalidate a specific query by key
    ///
    /// - Parameter key: The query key to invalidate
    /// - Parameter source: Optional source identifier for debugging
    public func invalidate<K: QueryKey>(key: K, source: String? = nil) async {
        do {
            try await invalidationTracker.withInvalidation(key: key.cacheKey, source: source) {
                try? await cache.invalidate(key: key.cacheKey)

                if let observer = activeQueries[key.cacheKey]?.observer {
                    Task {
                        await observer.triggerRefetch()
                    }
                }
            }
        } catch {
            // Cycle detected - already logged
        }
    }

    /// Invalidate by tag, throwing on cycle detection
    ///
    /// Use this variant when you want explicit error handling for cycles.
    public func invalidateOrThrow(tag: QueryTag, source: String? = nil) async throws {
        try await invalidationTracker.withInvalidation(tag: tag, source: source) {
            let invalidatedKeys = try? await cache.invalidate(tag: tag)

            for key in invalidatedKeys ?? [] {
                if let observer = activeQueries[key]?.observer {
                    Task {
                        await observer.triggerRefetch()
                    }
                }
            }

            cleanupActiveQueries()
        }
    }

    /// Get invalidation tracking statistics
    public var invalidationStats: InvalidationTracker.Stats {
        invalidationTracker.stats
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

    func registerActiveObserver(_ observer: QueryObserverProtocol, forKey key: String) {
        activeQueries[key] = AnyWeakQueryObserver(observer)
        cleanupActiveQueries()
    }

    func unregisterActiveObserver(_ observer: QueryObserverProtocol, forKey key: String) {
        if let existing = activeQueries[key]?.observer, existing === observer {
            activeQueries.removeValue(forKey: key)
        }
        cleanupActiveQueries()
    }
}

// MARK: - Type-Erased Observer Wrapper

/// Weak wrapper for active query tracking
private final class AnyWeakQueryObserver: @unchecked Sendable {
    private weak var _observer: AnyObject?
    
    init<K: QueryKey>(_ observer: QueryObserver<K>) {
        self._observer = observer
    }

    init(_ observer: QueryObserverProtocol) {
        self._observer = observer
    }
    
    var observer: (any QueryObserverProtocol)? {
        _observer as? any QueryObserverProtocol
    }
}

/// Protocol for type-erased query observer access
@MainActor
protocol QueryObserverProtocol: AnyObject {
    func triggerRefetch() async
}

extension QueryObserver: QueryObserverProtocol {
    func triggerRefetch() async {
        _ = await refetch()
    }
}

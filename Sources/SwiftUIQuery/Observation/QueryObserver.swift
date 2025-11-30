import Foundation
#if canImport(Observation)
import Observation
#endif

/// Bridges cache changes to @Observable for SwiftUI integration.
///
/// QueryObserver manages the lifecycle of a query:
/// 1. Checks cache for existing data
/// 2. Returns cached data immediately if available
/// 3. Triggers background refetch if data is stale
/// 4. Subscribes to cache changes for reactive updates
#if canImport(Observation)
@Observable
#endif
@MainActor
public final class QueryObserver<K: QueryKey> {
    // MARK: - Public State
    
    /// The current query state
    public private(set) var state: QueryState<K.Response>
    
    // MARK: - Private Properties

    private let key: K
    private let fetcher: @Sendable () async throws -> K.Response
    private let cache: QueryCache
    private let options: QueryOptions
    private weak var client: QueryClient?

    private var observationTask: Task<Void, Never>?
    private var fetchTask: Task<K.Response, Error>?
    private var isStarted = false
    private var isObserving = false  // True once observeCacheChanges() is running

    // MARK: - Initialization

    public init(
        key: K,
        fetcher: @escaping @Sendable () async throws -> K.Response,
        cache: QueryCache,
        options: QueryOptions = .default,
        client: QueryClient? = nil
    ) {
        self.key = key
        self.fetcher = fetcher
        self.cache = cache
        self.options = options
        self.client = client
        self.state = QueryState()
    }
    
    // MARK: - Lifecycle
    
    /// Start observing the cache and fetching data
    public func startObserving() {
        guard !isStarted else { return }
        isStarted = true
        
        observationTask = Task { [weak self] in
            guard let self else { return }
            
            // Initial cache check
            await self.loadFromCache()
            
            // Subscribe to cache changes
            await self.observeCacheChanges()
        }
    }
    
    /// Stop observing and cancel pending fetches
    public func stopObserving() {
        isStarted = false
        observationTask?.cancel()
        observationTask = nil
        fetchTask?.cancel()
        fetchTask = nil
    }
    
    // MARK: - Public Actions
    
    /// Manually trigger a refetch
    @discardableResult
    public func refetch() async -> K.Response? {
        await fetch(force: true)
    }
    
    /// Invalidate and refetch
    ///
    /// Routes through QueryClient to ensure proper cycle detection via InvalidationTracker.
    public func invalidate() async {
        if let client {
            // Route through QueryClient for cycle detection
            await client.invalidate(key: key, source: "QueryObserver<\(K.self)>")
        } else {
            // Fallback: direct cache invalidation (no cycle detection)
            try? await cache.invalidate(key: key.cacheKey)
            await refetch()
        }
    }
    
    // MARK: - Private Methods
    
    private func loadFromCache() async {
        do {
            if let cached = try await cache.get(key: key.cacheKey, as: K.Response.self) {
                state.setData(cached.data)
                
                // Background refetch if stale
                if cached.isStale {
                    await fetchInBackground()
                }
            } else {
                // No cache - fetch immediately
                await fetch(force: false)
            }
        } catch {
            // Cache read failed - fetch from network
            await fetch(force: false)
        }
    }
    
    private func observeCacheChanges() async {
        isObserving = true
        defer { isObserving = false }

        for await entry in await cache.observe(key: key.cacheKey) {
            guard !Task.isCancelled else { break }

            if let entry {
                do {
                    let data = try entry.decode(as: K.Response.self)
                    state.setData(data)

                    if entry.isStale {
                        await fetchInBackground()
                    }
                } catch {
                    // Decode error - data corrupted, refetch
                    await fetch(force: true)
                }
            }
        }
    }
    
    @discardableResult
    private func fetch(force: Bool) async -> K.Response? {
        // Avoid duplicate fetches unless forced
      if !force, fetchTask != nil { return try? await fetchTask?.value }

        state.setFetching(true)
        defer { state.setFetching(false) }
        
        var lastError: Error?
        
        for attempt in 0..<options.retryCount {
            do {
                let data = try await fetcher()
                
                try await cache.set(
                    key: key.cacheKey,
                    data: data,
                    tags: key.tags,
                    staleTime: options.staleTime,
                    cacheTime: options.cacheTime
                )

                // Only set data directly if observation loop isn't running yet.
                // When observing, the cache change will trigger setData via observeCacheChanges().
                if !isObserving {
                    state.setData(data)
                }
                return data
            } catch {
                lastError = error
                
                // Don't retry on cancellation
                if error is CancellationError { break }
                
                // Wait before retry
                if attempt < options.retryCount - 1 {
                    try? await Task.sleep(for: options.retryDelay)
                }
            }
        }
        
        if let error = lastError {
            state.setError(error)
        }
        
        return nil
    }
    
    private func fetchInBackground() async {
        // Dedupe background fetches
        guard fetchTask == nil else { return }

        fetchTask = Task { [fetcher] in
            try await fetcher()
        }

        defer { fetchTask = nil }

        state.setFetching(true)
        defer { state.setFetching(false) }

        do {
            let data = try await fetchTask!.value

            try? await cache.set(
                key: key.cacheKey,
                data: data,
                tags: key.tags,
                staleTime: options.staleTime,
                cacheTime: options.cacheTime
            )

            // Set data directly if observation loop isn't running yet.
            // This handles the case when fetchInBackground is called from loadFromCache()
            // before observeCacheChanges() starts. When observing, the cache change will
            // trigger setData via the observation loop instead.
            if !isObserving {
                state.setData(data)
            }
        } catch {
            // Background fetch failure - keep stale data, just record error
            // Don't change status since we have valid (stale) data
            if !(error is CancellationError) {
                state.setError(error)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension QueryObserver {
    /// Access the underlying data directly
    public var data: K.Response? { state.data }
    
    /// Access the underlying error directly
    public var error: Error? { state.error }
    
    /// Check if currently loading
    public var isLoading: Bool { state.isLoading }
    
    /// Check if refetching in background
    public var isRefetching: Bool { state.isRefetching }
}

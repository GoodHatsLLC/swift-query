#if canImport(SwiftUI)
import SwiftUI

/// Property wrapper for declarative data fetching in SwiftUI.
///
/// `@Query` provides React Query-style data fetching with automatic caching,
/// background refetching, and SwiftUI integration.
///
/// ```swift
/// struct UserView: View {
///     let userId: Int
///
///     @Query(UserQuery(userId: userId)) { _ in
///         try await api.fetchUser(id: userId)
///     } var user
///
///     var body: some View {
///         switch user.result {
///         case .loading:
///             ProgressView()
///         case .success(let user):
///             Text(user.name)
///         case .error(let error):
///             Text(error.localizedDescription)
///         case .idle:
///             EmptyView()
///         }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct Query<K: QueryKey>: @preconcurrency DynamicProperty, Sendable {
    @Environment(\.queryClient) private var client
    @State private var observer: Synchronized<QueryObserver<K>?> = .init(nil)
    @State private var observerCacheKey: Synchronized<String?> = .init(nil)
    @Environment(\.self) private var env
    private let key: K
    private let options: QueryOptions
    private let fetcher: @MainActor (_ env: EnvironmentValues) async throws -> K.Response

    /// Initialize with a query key and fetcher
    public nonisolated init(
        _ key: K,
        options: QueryOptions = .default,
        fetch: @escaping @MainActor (_ env: EnvironmentValues) async throws -> K.Response
    ) {
        self.key = key
        self.options = options
        self.fetcher = fetch
    }
    
    /// Initialize with a query key, stale time, and fetcher (convenience)
    public nonisolated init(
        _ key: K,
        staleTime: Duration,
        fetch: @escaping @MainActor (_ env: EnvironmentValues) async throws -> K.Response
    ) {
        self.key = key
        self.options = QueryOptions(staleTime: staleTime)
        self.fetcher = fetch
    }
    
    public var wrappedValue: QueryObserver<K> {
        ensureObserver()
    }

    @MainActor
    public var projectedValue: QueryActions<K> {
        QueryActions(observer: observer.withLock{$0}, client: client, key: key)
    }
    
    public func update() {
        _ = ensureObserver()
    }

    private func ensureObserver() -> QueryObserver<K> {
        let it = Transferring(env)

        if observerCacheKey.withLock({ $0 }) != key.cacheKey {
            observer.withLock({ $0 })?.stopObserving()
            observer.withLock { $0 = nil }
            observerCacheKey.withLock { $0 = key.cacheKey }
        }

        if let existing = observer.withLock({ $0 }) {
            return existing
        }

        let newObserver = client.query(key, options: options, fetcher: { try await fetcher(it.value) })
        self.observer.withLock { $0 = newObserver }
        self.observerCacheKey.withLock { $0 = key.cacheKey }
        newObserver.startObserving()
        return newObserver
    }
}
#endif

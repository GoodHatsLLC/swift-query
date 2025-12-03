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
///     @Query(UserQuery(userId: userId)) {
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
@propertyWrapper
@MainActor
public struct Query<K: QueryKey>: @preconcurrency DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var observer: QueryObserver<K>?
    
    private let key: K
    private let options: QueryOptions
    private let fetcher: @Sendable () async throws -> K.Response
    
    /// Initialize with a query key and fetcher
    public init(
        _ key: K,
        options: QueryOptions = .default,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) {
        self.key = key
        self.options = options
        self.fetcher = fetcher
    }
    
    /// Initialize with a query key, stale time, and fetcher (convenience)
    public init(
        _ key: K,
        staleTime: Duration,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) {
        self.key = key
        self.options = QueryOptions(staleTime: staleTime)
        self.fetcher = fetcher
    }
    
    public var wrappedValue: QueryObserver<K> {
        if let observer {
            return observer
        }
        // This shouldn't happen in practice, but provide a fallback
        return QueryObserver(
            key: key,
            fetcher: fetcher,
            cache: client.cache,
            options: options
        )
    }
    
    public var projectedValue: QueryActions<K> {
        QueryActions(observer: observer, client: client, key: key)
    }
    
    public mutating func update() {
        if observer == nil {
            let newObserver = client.query(key, options: options, fetcher: fetcher)
            observer = newObserver
            newObserver.startObserving()
        }
    }
}

// MARK: - UseQuery View Modifier

/// View modifier for query lifecycle management
@MainActor
public struct UseQueryModifier<K: QueryKey>: ViewModifier {
    let key: K
    let options: QueryOptions
    let fetcher: @Sendable () async throws -> K.Response
    let content: (QueryObserver<K>) -> AnyView
    
    @Environment(\.queryClient) private var client
    @State private var observer: QueryObserver<K>?
    
    public func body(content: Content) -> some View {
        content
            .task(id: key.cacheKey) {
                // Only create a new observer if one doesn't exist.
                // Reusing the existing observer preserves QueryState across tab switches.
                if observer == nil {
                    observer = client.query(key, options: options, fetcher: fetcher)
                }
                observer?.startObserving()
            }
            .onDisappear {
                observer?.stopObserving()
            }
    }
}

// MARK: - UseQuery Function

/// Functional approach to using queries in views
///
/// ```swift
/// var body: some View {
///     useQuery(UserQuery(userId: id)) {
///         try await api.fetchUser(id: id)
///     } content: { query in
///         switch query.result {
///         case .success(let user):
///             Text(user.name)
///         default:
///             ProgressView()
///         }
///     }
/// }
/// ```
@MainActor
public struct UseQuery<K: QueryKey, Content: View>: View {
    let key: K
    let options: QueryOptions
    let fetcher: @Sendable () async throws -> K.Response
    let content: (QueryObserver<K>) -> Content

    @Environment(\.queryClient) private var client
    @State private var observer: QueryObserver<K>?

    public init(
        _ key: K,
        options: QueryOptions = .default,
        fetcher: @escaping @Sendable () async throws -> K.Response,
        @_implicitSelfCapture content: @escaping (QueryObserver<K>) -> Content
    ) {
        self.key = key
        self.options = options
        self.fetcher = fetcher
        self.content = content
    }
    
    public var body: some View {
        Group {
            if let observer {
                content(observer)
            } else {
                ProgressView()
            }
        }
        .task(id: key.cacheKey) {
            // Only create a new observer if one doesn't exist.
            // Reusing the existing observer preserves QueryState (with cached data)
            // across tab switches, preventing the brief loading flash.
            if observer == nil {
                observer = client.query(key, options: options, fetcher: fetcher)
            }
            observer?.startObserving()
        }
        .onDisappear {
            observer?.stopObserving()
        }
    }
}
#endif

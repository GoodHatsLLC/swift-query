#if canImport(SwiftUI)
import SwiftUI

// MARK: - Environment Key

@MainActor
private struct QueryClientKey: @preconcurrency EnvironmentKey {
    static let defaultValue: QueryClient = QueryClient()
}

extension EnvironmentValues {
    /// SwiftQuery's internal query client for this environment (cache + invalidation coordinator).
    ///
    /// This is separate from any app-defined "API client" you might also inject into the environment
    /// for actual network requests.
    public var queryClient: QueryClient {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// Provides a custom query client to the view hierarchy
    public func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}

// MARK: - Query Client Provider

/// A view that provides a QueryClient to its content
@MainActor
public struct QueryClientProvider<Content: View>: View {
    private let client: QueryClient
    private let content: Content

    public init(
        cacheConfiguration: CacheDatabaseConfiguration = .init(),
        defaultOptions: QueryOptions = .default,
        @ViewBuilder content: () -> Content
    ) {
        self.client = QueryClient(
            cacheConfiguration: cacheConfiguration,
            defaultOptions: defaultOptions
        )
        self.content = content()
    }

    public init(
        client: QueryClient,
        @ViewBuilder content: () -> Content
    ) {
        self.client = client
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.queryClient, client)
    }
}
#endif

# SwiftQuery

SwiftQuery makes data fetching in SwiftUI simpler and faster by handling caching, retries, and background refresh so your views stay in sync with server state. It also supports tag-based invalidation (you tag related queries and invalidate a tag to refresh everything that depends on it). It’s inspired by React Query.

## Features

- Declarative data fetching via `@Query`
- Mutations via `@Mutation` with automatic invalidation
- Hierarchical invalidation with `QueryTag` prefix matching
- Persistent cache backed by SQLite/GRDB (or in-memory)
- Stale-while-revalidate behavior (return cached data, refresh in background)

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.1+ (Xcode 26+ recommended)

## Installation (Swift Package Manager)

Add the package in Xcode (File → Add Package Dependencies…) or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/GoodHatsLLC/swift-query.git", from: "0.5.0")
]
```

Then add `SwiftQuery` as a dependency of your target.

## Quick Start

### 1) Define a query key

```swift
import SwiftQuery

struct UserQuery: QueryKey {
    typealias Response = User
    let id: Int

    var cacheKey: String { "users:\(id)" }
    var tags: Set<QueryTag> { ["users", QueryTag("users", "\(id)")] }
}
```

### 2) Fetch in SwiftUI

If your app exposes an API client via SwiftUI `@Environment`, you can access it inside the `@Query` fetch closure (and `@Mutation` function) through the `EnvironmentValues` parameter.

```swift
import SwiftUI
import SwiftQuery

private struct APIClientKey: EnvironmentKey {
    static let defaultValue = APIClient()
}

extension EnvironmentValues {
    var apiClient: APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}

struct UserView: View {
    let userId: Int

    @Query(UserQuery(id: userId)) { env in
        try await env.apiClient.fetchUser(id: userId)
    } var user

    var body: some View {
        switch user.result {
        case .idle, .loading:
            ProgressView()
        case .success(let user):
            Text(user.name)
        case .error(let error):
            Text(error.localizedDescription)
        }
    }
}
```

### 3) Provide a shared client (recommended)

`@Query` and `@Mutation` use a `QueryClient` from the SwiftUI environment (`EnvironmentValues.queryClient`) to coordinate caching and invalidation.
SwiftQuery provides a default client automatically, but `QueryClientProvider` is the recommended way to make the shared client explicit and configure it:

- Ensure the entire view tree shares a single cache + invalidation graph
- Choose cache storage (`.persistent` stores in Application Support; the default is cache-directory backed and may be evicted)
- Set global defaults via `QueryOptions` (stale time, retries, focus/reconnect refetch, etc.)

```swift
import SwiftUI
import SwiftQuery

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            QueryClientProvider(cacheConfiguration: .persistent) {
                ContentView()
            }
            .environment(\.apiClient, APIClient())
        }
    }
}
```

If you already create and own a `QueryClient` (e.g. in tests, previews, or when you want to pass a custom instance), you can inject it directly with `QueryClientProvider(client:)` or `.queryClient(_:)`.

## Invalidation and Mutations

Use `QueryTag` to model invalidation boundaries. Invalidating a parent tag invalidates all children (prefix match).

```swift
import SwiftUI
import SwiftQuery

struct CreatePostView: View {
    @Mutation(invalidates: "posts", "feed") { env, input in
        try await env.apiClient.createPost(input)
    } var createPost

    var body: some View {
        Button("Create") {
            Task {
                _ = try await createPost.mutate(CreatePostInput(title: "Hello"))
            }
        }
        .disabled(createPost.isPending)
    }
}
```

### More invalidation examples

#### Invalidate from inside a view (`$query`)

Use `.refetch()` when you just want to rerun the fetcher, and `.invalidate()` when you want to mark the cached value stale (and refetch).

```swift
struct UserView: View {
    let userId: Int

    @Query(UserQuery(id: userId)) { env in
        try await env.apiClient.fetchUser(id: userId)
    } var user

    var body: some View {
        VStack {
            Button("Refetch (no invalidation)") {
                Task { await $user.refetch() }
            }

            Button("Invalidate + refetch") {
                Task { await $user.invalidate() }
            }
        }
    }
}
```

#### Invalidate a specific query key

Useful when a mutation affects exactly one cached entry.

```swift
struct ProfileView: View {
    @Environment(\.queryClient) private var queryClient
    let userId: Int

    var body: some View {
        Button("Refresh user") {
            Task {
                await queryClient.invalidate(key: UserQuery(id: userId))
            }
        }
    }
}
```

#### Invalidate a parent tag (fan-out to many queries)

If your `QueryKey.tags` include a hierarchy like `users` → `users.<id>`, then invalidating `users` refreshes any active user queries at once.

```swift
@Environment(\.queryClient) private var queryClient

Button("Refresh all users") {
    Task {
        await queryClient.invalidate(tag: QueryTag("users"))
    }
}
```

If you want to invalidate only a single entity (and its “children”), invalidate the more specific tag:

```swift
await queryClient.invalidate(tag: QueryTag("users", "\(userId)"))
```

#### Invalidate in response to external events

For example, after a websocket or push notification indicates server-side data changed:

```swift
struct FeedView: View {
    @Environment(\.queryClient) private var queryClient

    var body: some View {
        FeedList()
            .onReceive(NotificationCenter.default.publisher(for: .init("feedDidChange"))) { _ in
                Task { await queryClient.invalidate(tag: QueryTag("feed")) }
            }
    }
}
```

Notes:

- `QueryClient` (`EnvironmentValues.queryClient`) is SwiftQuery’s internal cache + invalidation coordinator, typically provided via `QueryClientProvider`.
- Your app’s API client (like `EnvironmentValues.apiClient` above) is a separate, consumer-defined dependency used to actually talk to the network.

## Documentation

This package ships with DocC documentation in `Sources/SwiftQuery/SwiftQuery.docc`.

- DocC (CLI): `swift package generate-documentation --target SwiftQuery`
- DocC (static hosting): `swift package --allow-writing-to-directory ./docs generate-documentation --target SwiftQuery --output-path ./docs --transform-for-static-hosting`
- Xcode: Product → Build Documentation

## Example App

This repository includes a small SwiftUI example target (`TestApp`). Open the package in Xcode and run the `TestApp` scheme, or try `swift run TestApp` on macOS.

```sh
swift run TestApp
```

## Development

- Run tests: `swift test`
- Build the package: `swift build`

## License

MIT. See `LICENSE`.

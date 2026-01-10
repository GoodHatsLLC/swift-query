# Getting Started

SwiftQuery is a small, SwiftUI-first data fetching layer inspired by React Query.

## Define a Query Key

Create a type that conforms to ``QueryKey``. The key provides a stable cache identifier and
the tags used for invalidation.

```swift
import SwiftQuery

struct UserQuery: QueryKey {
    typealias Response = User
    let id: Int

    var cacheKey: String { "users:\(id)" }
    var tags: Set<QueryTag> { [.users, .user(id)] }
}
```

## Fetch In SwiftUI

Use ``Query`` to fetch and observe data, and use ``QueryActions`` through the projected value
to refetch or invalidate.

The `APIClient` in this example is your app’s network dependency. SwiftQuery separately uses a ``QueryClient`` (below) for caching and invalidation.

```swift
import SwiftUI
import SwiftQuery

struct UserView: View {
    let api: APIClient
    let userId: Int

    @Query(UserQuery(id: userId)) { _ in
        try await api.fetchUser(id: userId)
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

## Configure A Shared Client

``Query`` and ``Mutation`` use a ``QueryClient`` from the SwiftUI environment to coordinate caching and invalidation.
SwiftQuery ships with an environment default, but wrapping your app in ``QueryClientProvider`` is the recommended way to make the shared client explicit and configure it:

- Ensure the entire view tree shares a single cache + invalidation graph
- Choose cache storage (``.persistent`` stores in Application Support; the default is cache-directory backed and may be evicted)
- Set global defaults via ``QueryOptions`` (stale time, retries, focus/reconnect refetch, etc.)

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
        }
    }
}
```

## Next Steps

- Learn how to model invalidation with ``QueryTag``.
- Customize behavior with ``QueryOptions`` (stale time, retries, focus/reconnect refetch).

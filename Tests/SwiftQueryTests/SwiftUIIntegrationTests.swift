#if canImport(SwiftUI) && canImport(AppKit)

import AppKit
import SwiftUI
import XCTest
@testable import SwiftQuery

private struct TestAPIClient: Sendable {
    let token: String
}

private struct TestAPIClientKey: EnvironmentKey {
    static let defaultValue = TestAPIClient(token: "")
}

private extension EnvironmentValues {
    var testAPIClient: TestAPIClient {
        get { self[TestAPIClientKey.self] }
        set { self[TestAPIClientKey.self] = newValue }
    }
}

@MainActor
final class SwiftUIIntegrationTests: XCTestCase {
    func testQueryPropertyWrapperFetchesUsingEnvironmentClient() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        struct TestView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: 1),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { env in
                        _ = env
                        await counter.increment()
                        return TestUser(id: 1, name: "User 1")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                TestView(counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: "user:1", as: TestUser.self)
            return cached?.data.name == "User 1"
        }
    }

    func testQueryPropertyWrapperReplacesObserverWhenKeyChanges() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        final class Model: ObservableObject {
            @Published var userId: Int = 1
        }

        struct QueryView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(userId: Int, counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: userId),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { [userId] env in
                        _ = env
                        await counter.increment()
                        return TestUser(id: userId, name: "User \(userId)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        struct ContainerView: View {
            @ObservedObject var model: Model
            let counter: FetchCounter

            var body: some View {
                QueryView(userId: model.userId, counter: counter)
            }
        }

        let model = Model()

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                ContainerView(model: model, counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) {
            await counter.value == 1
        }

        model.userId = 2

        try await eventually(timeout: 3.0) {
            let cached2 = try? await cache.get(key: "user:2", as: TestUser.self)
            return cached2?.data.name == "User 2"
        }
    }

    func testQueryProjectedValueInvalidateTriggersRefetch() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        @MainActor
        final class Sink: ObservableObject {
            var invalidate: (() async -> Void)?
        }

        struct TestView: View {
            @ObservedObject var sink: Sink

            @Query
            private var user: QueryObserver<TestUserQuery>

            init(sink: Sink, counter: FetchCounter) {
                self.sink = sink
                _user = Query(
                    TestUserQuery(userId: 99),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { env in
                        _ = env
                        let count = await counter.incrementAndGet()
                        return TestUser(id: 99, name: "Fetch \(count)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
                    .onAppear {
                        sink.invalidate = { await $user.invalidate() }
                    }
            }
        }

        let sink = await MainActor.run { Sink() }

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                TestView(sink: sink, counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 5.0) {
            let cached = try? await cache.get(key: "user:99", as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        try await eventually(timeout: 5.0) {
            sink.invalidate != nil
        }

        await sink.invalidate?()

        try await eventually(timeout: 5.0) {
            let cached = try? await cache.get(key: "user:99", as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testMutationPropertyWrapperInvalidatesUsingEnvironmentClient() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)

        let key = TestUserQuery(userId: 10)
        try await cache.set(
            key: key.cacheKey,
            data: TestUser(id: 10, name: "Cached"),
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        @MainActor
        final class Sink: ObservableObject {
            var run: (() async throws -> Void)?
        }

        struct MutationView: View {
            @ObservedObject var sink: Sink

            @Mutation(
                invalidates: QueryTag("users"),
                mutationFn: { () async throws -> Void in () }
            )
            var mutation

            var body: some View {
                Color.clear
                    .task {
                        sink.run = { try await mutation.mutate() }
                    }
            }
        }

        let sink = await MainActor.run { Sink() }
        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                MutationView(sink: sink)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        try await eventually(timeout: 2.0) {
            sink.run != nil
        }

        defer { window.close() }
        try await sink.run?() ?? XCTFail("Expected mutation runner")

        let cached = try await cache.get(key: key.cacheKey, as: TestUser.self)
        XCTAssertEqual(cached?.isStale, true)
    }

    func testMutationPropertyWrapperPassesEnvironmentValuesToMutationFn() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)

        @MainActor
        final class Sink: ObservableObject {
            var run: (() async throws -> Void)?
            var observedToken: String?
            var observedQueryClientID: ObjectIdentifier?
        }

        struct MutationView: View {
            @ObservedObject var sink: Sink

            @Mutation private var mutation: MutationState<Void, Void>

            init(sink: Sink) {
                self.sink = sink
                self._mutation = Mutation(
                    invalidates: [],
                    mutationFn: { env, _ in
                        sink.observedToken = env.testAPIClient.token
                        sink.observedQueryClientID = ObjectIdentifier(env.queryClient)
                    }
                )
            }

            var body: some View {
                Color.clear
                    .task {
                        sink.run = { try await mutation.mutate() }
                    }
            }
        }

        let sink = await MainActor.run { Sink() }
        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                MutationView(sink: sink)
            }
            .environment(\.testAPIClient, TestAPIClient(token: "abc"))
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) {
            sink.run != nil
        }

        try await sink.run?() ?? XCTFail("Expected mutation runner")

        XCTAssertEqual(sink.observedToken, "abc")
        XCTAssertEqual(sink.observedQueryClientID, ObjectIdentifier(client))
    }
}

// MARK: - Helpers

private actor FetchCounter {
    private var count = 0

    func increment() { count += 1 }

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        await MainActor.run {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition not met before timeout")
}

#endif

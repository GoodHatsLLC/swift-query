import GRDB
import XCTest
@testable import SwiftQuery

@MainActor
final class CancellationBehaviorTests: XCTestCase {
    func testQueryCacheObserveCancelsPromptly() async throws {
        let cache = try QueryCache(configuration: .inMemory)
        let key = "cancel:observe"

        try await cache.set(
            key: key,
            data: TestUser(id: 1, name: "Seeded"),
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let started = expectation(description: "Received first observation")
        let finished = expectation(description: "Observation task finished after cancellation")

        let task = Task {
            defer { finished.fulfill() }
            var didStart = false
            for await entry in await cache.observe(key: key) {
                if entry != nil, !didStart {
                    didStart = true
                    started.fulfill()
                }
                // After the first value, block awaiting further values so the task
                // stays alive until it is cancelled.
                if didStart {
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        break
                    }
                }
            }
        }

        await fulfillment(of: [started], timeout: 1.0)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1.0)
    }

    func testCancellingBackgroundFetchDoesNotSetErrorOrClearCachedData() async throws {
        let configuration = CacheDatabaseConfiguration.inMemory
        let dbPool = try createDatabasePool(configuration: configuration)
        let cache = QueryCache(dbPool: dbPool)

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 987)
        let seeded = TestUser(id: 987, name: "Seeded")

        try await cache.set(
            key: key.cacheKey,
            data: seeded,
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        // Force time-based staleness without toggling invalidation.
        _ = try await dbPool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key.cacheKey)
                .updateAll(db, QueryCacheEntry.Columns.staleAt.set(to: Date.distantPast))
        }

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                // Make this cancellable and long enough that the test can cancel.
                try await Task.sleep(for: .seconds(2))
                return TestUser(id: 987, name: "Fetched")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.isFetching
        }

        observer.stopObserving()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(observer.state.data?.name, "Seeded")
        XCTAssertNil(observer.state.error)
        XCTAssertNil(observer.state.backgroundError)
        XCTAssertTrue(observer.state.isSuccess)
    }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition not met before timeout")
}

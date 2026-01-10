import XCTest
@testable import SwiftQuery

@MainActor
final class QueryObserverRetryTests: XCTestCase {
    func testObserverRetriesAndEventuallySucceeds() async throws {
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 9000)

        let attempts = Counter()
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                retryCount: 2,
                retryDelay: .milliseconds(1)
            ),
            fetcher: {
                let n = await attempts.incrementAndGet()
                if n == 1 { throw TestError.test }
                return TestUser(id: 9000, name: "Success")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Success"
        }
        let value = await attempts.value()
        XCTAssertEqual(value, 2)
    }
}

private actor Counter {
    private var count = 0

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    func value() -> Int { count }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition not met before timeout")
}

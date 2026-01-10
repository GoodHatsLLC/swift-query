#if canImport(Observation)

import XCTest
@testable import SwiftQuery

@MainActor
final class ObservationTrackingTests: XCTestCase {
    func testTrackCallsOnChangeWhenObservedValueChanges() async throws {
        let cache = try QueryCache(configuration: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 1)

        let observer = client.query(key, fetcher: { TestUser(id: 1, name: "Initial") })

        let changeExpectation = expectation(description: "Observation change callback fired")
        observer.track({ observer.state.data }, onChange: {
            changeExpectation.fulfill()
        })

        observer.state.setData(TestUser(id: 1, name: "Updated"))

        await fulfillment(of: [changeExpectation], timeout: 1.0)
    }
}

#endif


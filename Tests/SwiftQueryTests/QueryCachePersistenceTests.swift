import XCTest
@testable import SwiftQuery

@MainActor
final class QueryCachePersistenceTests: XCTestCase {
    func testPersistentCacheSurvivesNewQueryClientInstance() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftQuery-Persistence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = CacheDatabaseConfiguration(path: url.path, useWAL: false)
        let key = TestUserQuery(userId: 4242)

        do {
            let client = QueryClient(cacheConfiguration: configuration)
            await client.setQueryData(key, data: TestUser(id: 4242, name: "Persisted"))
        }

        do {
            let client = QueryClient(cacheConfiguration: configuration)
            let loaded = await client.getQueryData(key)
            XCTAssertEqual(loaded?.name, "Persisted")
        }
    }
}


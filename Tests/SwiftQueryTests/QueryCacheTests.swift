import XCTest
@testable import SwiftQuery

final class QueryCacheTests: XCTestCase {
    
    var cache: QueryCache!
    
    override func setUp() async throws {
        // Use in-memory database for tests
        cache = try QueryCache(configuration: .inMemory)
    }
    
    func testSetAndGet() async throws {
        let user = TestUser(id: 1, name: "Test")
        
        try await cache.set(
            key: "user:1",
            data: user,
            tags: [.users, .user(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data, user)
        XCTAssertFalse(result?.isStale ?? true)
    }
    
    func testGetNonExistent() async throws {
        let result = try await cache.get(key: "nonexistent", as: TestUser.self)
        XCTAssertNil(result)
    }
    
    func testExists() async throws {
        let user = TestUser(id: 1, name: "Test")
        
        XCTAssertFalse(try await cache.exists(key: "user:1"))
        
        try await cache.set(
            key: "user:1",
            data: user,
            tags: [.users],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        XCTAssertTrue(try await cache.exists(key: "user:1"))
    }
    
    func testInvalidateByTag() async throws {
        // Set up multiple users
        for i in 1...3 {
            try await cache.set(
                key: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [.users, .user(i)],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }
        
        // Invalidate all users
        let invalidated = try await cache.invalidate(tag: .users)
        XCTAssertEqual(invalidated.count, 3)
        
        // Check they're now stale
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertTrue(result?.isStale ?? false)
    }
    
    func testInvalidateSpecificTag() async throws {
        // Set up users
        for i in 1...3 {
            try await cache.set(
                key: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [.users, .user(i)],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }
        
        // Invalidate only user 2
        let invalidated = try await cache.invalidate(tag: .user(2))
        XCTAssertEqual(invalidated.count, 1)
        XCTAssertTrue(invalidated.contains("user:2"))
        
        // User 1 should still be fresh
        let result1 = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertFalse(result1?.isStale ?? true)
        
        // User 2 should be stale
        let result2 = try await cache.get(key: "user:2", as: TestUser.self)
        XCTAssertTrue(result2?.isStale ?? false)
    }
    
    func testHierarchicalInvalidation() async throws {
        // Set up user and their posts
        try await cache.set(
            key: "user:1",
            data: TestUser(id: 1, name: "User 1"),
            tags: [.users, .user(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        try await cache.set(
            key: "user:1:posts",
            data: ["Post 1", "Post 2"],
            tags: [.user(1), .userPosts(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        // Invalidate user 1 - should cascade to posts
        let invalidated = try await cache.invalidate(tag: .user(1))
        XCTAssertEqual(invalidated.count, 2)
        
        let userResult = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertTrue(userResult?.isStale ?? false)
        
        let postsResult = try await cache.get(key: "user:1:posts", as: [String].self)
        XCTAssertTrue(postsResult?.isStale ?? false)
    }
    
    func testRemove() async throws {
        let user = TestUser(id: 1, name: "Test")
        
        try await cache.set(
            key: "user:1",
            data: user,
            tags: [.users],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        try await cache.remove(key: "user:1")
        
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertNil(result)
    }
    
    func testClear() async throws {
        for i in 1...5 {
            try await cache.set(
                key: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [.users],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }
        
        try await cache.clear()
        
        for i in 1...5 {
            let result = try await cache.get(key: "user:\(i)", as: TestUser.self)
            XCTAssertNil(result)
        }
    }
    
    func testStats() async throws {
        for i in 1...3 {
            try await cache.set(
                key: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [.users],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }
        
        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 3)
        XCTAssertEqual(stats.staleEntries, 0)
    }
    
    func testUpsertBehavior() async throws {
        let user1 = TestUser(id: 1, name: "Original")
        let user2 = TestUser(id: 1, name: "Updated")
        
        try await cache.set(
            key: "user:1",
            data: user1,
            tags: [.users],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        try await cache.set(
            key: "user:1",
            data: user2,
            tags: [.users],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )
        
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertEqual(result?.data.name, "Updated")
        
        // Should still only have 1 entry
        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 1)
    }
}

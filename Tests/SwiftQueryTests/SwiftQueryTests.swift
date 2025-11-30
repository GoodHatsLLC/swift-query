import XCTest
@testable import SwiftQuery

final class QueryTagTests: XCTestCase {
    
    func testTagMatching() {
        let users = QueryTag("users")
        let user123 = QueryTag("users", "123")
        let user123Posts = QueryTag("users", "123", "posts")
        let posts = QueryTag("posts")
        
        // Parent matches children
        XCTAssertTrue(users.matches(user123))
        XCTAssertTrue(users.matches(user123Posts))
        XCTAssertTrue(user123.matches(user123Posts))
        
        // Self matches
        XCTAssertTrue(users.matches(users))
        XCTAssertTrue(user123.matches(user123))
        
        // Child doesn't match parent
        XCTAssertFalse(user123.matches(users))
        XCTAssertFalse(user123Posts.matches(user123))
        
        // Unrelated tags don't match
        XCTAssertFalse(users.matches(posts))
        XCTAssertFalse(posts.matches(users))
    }
    
    func testTagJsonEncoding() {
        let tag = QueryTag("users", "123", "posts")
        let json = tag.jsonEncoded
        
        XCTAssertTrue(json.contains("users"))
        XCTAssertTrue(json.contains("123"))
        XCTAssertTrue(json.contains("posts"))
    }
    
    func testTagDescription() {
        let tag = QueryTag("users", "123", "posts")
        XCTAssertEqual(tag.description, "users.123.posts")
    }
    
    func testTagFactories() {
        let user = QueryTag.user(123)
        XCTAssertEqual(user.segments, ["users", "123"])
        
        let userPosts = QueryTag.userPosts(456)
        XCTAssertEqual(userPosts.segments, ["users", "456", "posts"])
    }
}

final class QueryStateTests: XCTestCase {
    
    @MainActor
    func testInitialState() {
        let state = QueryState<String>()
        
        XCTAssertNil(state.data)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.fetchStatus, .idle)
        XCTAssertFalse(state.isPending)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isSuccess)
        XCTAssertFalse(state.isError)
    }
    
    @MainActor
    func testSetData() {
        let state = QueryState<String>()
        state.setData("Hello")
        
        XCTAssertEqual(state.data, "Hello")
        XCTAssertEqual(state.status, .success)
        XCTAssertTrue(state.isSuccess)
        XCTAssertNotNil(state.dataUpdatedAt)
    }
    
    @MainActor
    func testSetError() {
        let state = QueryState<String>()
        state.setError(TestError.test)
        
        XCTAssertNotNil(state.error)
        XCTAssertEqual(state.status, .error)
        XCTAssertTrue(state.isError)
        XCTAssertEqual(state.failureCount, 1)
    }
    
    @MainActor
    func testSetFetching() {
        let state = QueryState<String>()
        state.setFetching(true)
        
        XCTAssertEqual(state.fetchStatus, .fetching)
        XCTAssertEqual(state.status, .pending)
        XCTAssertTrue(state.isPending)
        XCTAssertTrue(state.isLoading)
    }
    
    @MainActor
    func testIsRefetching() {
        let state = QueryState<String>()
        state.setData("Hello")
        state.setFetching(true)
        
        XCTAssertTrue(state.isRefetching)
        XCTAssertTrue(state.isSuccess)  // Still success because we have data
    }
    
    @MainActor
    func testReset() {
        let state = QueryState<String>()
        state.setData("Hello")
        state.reset()
        
        XCTAssertNil(state.data)
        XCTAssertEqual(state.status, .idle)
    }
}

final class QueryOptionsTests: XCTestCase {
    
    func testDefaultOptions() {
        let options = QueryOptions.default
        
        XCTAssertEqual(options.staleTime, .zero)
        XCTAssertEqual(options.cacheTime, .minutes(5))
        XCTAssertEqual(options.retryCount, 3)
    }
    
    func testCustomOptions() {
        let options = QueryOptions(
            staleTime: .minutes(10),
            cacheTime: .hours(1),
            retryCount: 5
        )
        
        XCTAssertEqual(options.staleTime, .minutes(10))
        XCTAssertEqual(options.cacheTime, .hours(1))
        XCTAssertEqual(options.retryCount, 5)
    }
}

final class DurationExtensionTests: XCTestCase {
    
    func testMinutes() {
        let duration = Duration.minutes(5)
        XCTAssertEqual(duration.timeInterval, 300)
    }
    
    func testHours() {
        let duration = Duration.hours(2)
        XCTAssertEqual(duration.timeInterval, 7200)
    }
    
    func testDays() {
        let duration = Duration.days(1)
        XCTAssertEqual(duration.timeInterval, 86400)
    }
}

// MARK: - Test Helpers

enum TestError: Error {
    case test
}

struct TestUser: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct TestUserQuery: QueryKey {
    typealias Response = TestUser
    let userId: Int
    
    var cacheKey: String { "user:\(userId)" }
    var tags: Set<QueryTag> { [.users, .user(userId)] }
}

import XCTest
@testable import SwiftUIQuery

@MainActor
final class InvalidationTrackerTests: XCTestCase {

    // Helper tags
    private let usersTag = QueryTag("users")
    private let postsTag = QueryTag("posts")
    private let commentsTag = QueryTag("comments")

    // MARK: - Basic Tracking

    func testBeginEndInvalidation() {
        let tracker = InvalidationTracker()

        XCTAssertFalse(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 0)

        let token = try! tracker.beginInvalidation(tag: usersTag)
        XCTAssertTrue(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 1)

        tracker.endInvalidation(token)
        XCTAssertFalse(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    func testNestedInvalidations() {
        let tracker = InvalidationTracker()

        let token1 = try! tracker.beginInvalidation(tag: usersTag)
        XCTAssertEqual(tracker.currentDepth, 1)

        let token2 = try! tracker.beginInvalidation(tag: postsTag)
        XCTAssertEqual(tracker.currentDepth, 2)

        let token3 = try! tracker.beginInvalidation(tag: commentsTag)
        XCTAssertEqual(tracker.currentDepth, 3)

        tracker.endInvalidation(token3)
        XCTAssertEqual(tracker.currentDepth, 2)

        tracker.endInvalidation(token2)
        XCTAssertEqual(tracker.currentDepth, 1)

        tracker.endInvalidation(token1)
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    // MARK: - Cycle Detection

    func testCycleDetectionWithTags() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: false, logWarnings: false))

        // Start invalidating users
        let token1 = try! tracker.beginInvalidation(tag: usersTag)

        // Try to invalidate users again (cycle!)
        let token2 = try! tracker.beginInvalidation(tag: usersTag)

        // Token should indicate it was skipped
        XCTAssertTrue(token2.wasSkipped)
        XCTAssertEqual(tracker.stats.cyclesDetected, 1)

        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }

    func testCycleDetectionThrows() throws {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: true, logWarnings: false))

        let token1 = try tracker.beginInvalidation(tag: usersTag)

        // Should throw on cycle
        XCTAssertThrowsError(try tracker.beginInvalidation(tag: usersTag)) { error in
            guard case InvalidationTracker.TrackerError.cycleDetected(let info) = error else {
                XCTFail("Expected cycleDetected error")
                return
            }
            XCTAssertEqual(info.trigger, "tag:users")
            XCTAssertEqual(info.depth, 1)
        }

        tracker.endInvalidation(token1)
    }

    func testCycleDetectionWithKeys() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: false, logWarnings: false))

        let token1 = try! tracker.beginInvalidation(key: "user:123")
        let token2 = try! tracker.beginInvalidation(key: "user:123") // cycle

        XCTAssertTrue(token2.wasSkipped)
        XCTAssertEqual(tracker.stats.cyclesDetected, 1)

        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }

    func testIndirectCycleDetection() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: false, logWarnings: false))

        // A -> B -> C -> A (indirect cycle)
        let tokenA = try! tracker.beginInvalidation(tag: usersTag, source: "A")
        let tokenB = try! tracker.beginInvalidation(tag: postsTag, source: "B")
        let tokenC = try! tracker.beginInvalidation(tag: commentsTag, source: "C")

        // Now try to go back to A
        let tokenA2 = try! tracker.beginInvalidation(tag: usersTag, source: "A2")
        XCTAssertTrue(tokenA2.wasSkipped)
        XCTAssertEqual(tracker.stats.cyclesDetected, 1)

        // Verify chain in stats
        XCTAssertEqual(tracker.currentChain.count, 3)
        XCTAssertEqual(tracker.currentChain[0].source, "A")
        XCTAssertEqual(tracker.currentChain[1].source, "B")
        XCTAssertEqual(tracker.currentChain[2].source, "C")

        tracker.endInvalidation(tokenA2)
        tracker.endInvalidation(tokenC)
        tracker.endInvalidation(tokenB)
        tracker.endInvalidation(tokenA)
    }

    // MARK: - Depth Limiting

    func testMaxDepthExceeded() {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 3, throwOnCycle: false, logWarnings: false))

        let token1 = try! tracker.beginInvalidation(tag: QueryTag("tag1"))
        let token2 = try! tracker.beginInvalidation(tag: QueryTag("tag2"))
        let token3 = try! tracker.beginInvalidation(tag: QueryTag("tag3"))

        // This should exceed max depth
        let token4 = try! tracker.beginInvalidation(tag: QueryTag("tag4"))
        XCTAssertTrue(token4.wasSkipped)
        XCTAssertEqual(tracker.stats.depthExceededCount, 1)

        tracker.endInvalidation(token4)
        tracker.endInvalidation(token3)
        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }

    func testMaxDepthThrows() throws {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 2, throwOnCycle: true, logWarnings: false))

        let token1 = try tracker.beginInvalidation(tag: QueryTag("tag1"))
        let token2 = try tracker.beginInvalidation(tag: QueryTag("tag2"))

        // Should throw on exceeding depth
        XCTAssertThrowsError(try tracker.beginInvalidation(tag: QueryTag("tag3"))) { error in
            guard case InvalidationTracker.TrackerError.maxDepthExceeded(let depth, let maxDepth, _) = error else {
                XCTFail("Expected maxDepthExceeded error")
                return
            }
            XCTAssertEqual(depth, 3)
            XCTAssertEqual(maxDepth, 2)
        }

        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }

    // MARK: - WithInvalidation

    func testWithInvalidation() async throws {
        let tracker = InvalidationTracker()

        var operationRan = false

        try await tracker.withInvalidation(tag: usersTag) {
            operationRan = true
            XCTAssertTrue(tracker.isInvalidating)
            XCTAssertEqual(tracker.currentDepth, 1)
        }

        XCTAssertTrue(operationRan)
        XCTAssertFalse(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    func testWithInvalidationCleansUpOnError() async {
        let tracker = InvalidationTracker()

        do {
            try await tracker.withInvalidation(tag: usersTag) {
                XCTAssertEqual(tracker.currentDepth, 1)
                throw CycleTestError.intentionalError
            }
            XCTFail("Should have thrown")
        } catch is CycleTestError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Tracker should be cleaned up
        XCTAssertFalse(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    // MARK: - Statistics

    func testStatistics() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: false, logWarnings: false))

        XCTAssertEqual(tracker.stats.totalInvalidations, 0)
        XCTAssertEqual(tracker.stats.cyclesDetected, 0)
        XCTAssertEqual(tracker.stats.maxDepthReached, 0)

        let token1 = try! tracker.beginInvalidation(tag: usersTag)
        XCTAssertEqual(tracker.stats.totalInvalidations, 1)
        XCTAssertEqual(tracker.stats.maxDepthReached, 1)

        let token2 = try! tracker.beginInvalidation(tag: postsTag)
        XCTAssertEqual(tracker.stats.totalInvalidations, 2)
        XCTAssertEqual(tracker.stats.maxDepthReached, 2)

        // Cycle
        _ = try! tracker.beginInvalidation(tag: usersTag)
        XCTAssertEqual(tracker.stats.totalInvalidations, 3)
        XCTAssertEqual(tracker.stats.cyclesDetected, 1)

        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }

    func testReset() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: false, logWarnings: false))

        _ = try! tracker.beginInvalidation(tag: usersTag)
        _ = try! tracker.beginInvalidation(tag: usersTag) // cycle

        XCTAssertEqual(tracker.stats.cyclesDetected, 1)
        XCTAssertTrue(tracker.isInvalidating)

        tracker.reset()

        XCTAssertEqual(tracker.stats.cyclesDetected, 0)
        XCTAssertFalse(tracker.isInvalidating)
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    // MARK: - Callback

    func testOnCycleDetectedCallback() {
        // Use nonisolated(unsafe) to satisfy Sendable requirement in test
        nonisolated(unsafe) var detectedCycle: InvalidationTracker.CycleInfo?

        let tracker = InvalidationTracker(configuration: .init(
            throwOnCycle: false,
            logWarnings: false,
            onCycleDetected: { info in
                detectedCycle = info
            }
        ))

        let token1 = try! tracker.beginInvalidation(tag: usersTag, source: "source1")
        _ = try! tracker.beginInvalidation(tag: usersTag, source: "source2")

        XCTAssertNotNil(detectedCycle)
        XCTAssertEqual(detectedCycle?.trigger, "tag:users")
        XCTAssertEqual(detectedCycle?.chain.count, 1)
        XCTAssertEqual(detectedCycle?.chain[0].source, "source1")

        tracker.endInvalidation(token1)
    }

    // MARK: - Configuration Presets

    func testStrictConfiguration() {
        let config = InvalidationTracker.Configuration.strict
        XCTAssertEqual(config.maxDepth, 5)
        XCTAssertTrue(config.throwOnCycle)
        XCTAssertTrue(config.logWarnings)
    }

    func testPermissiveConfiguration() {
        let config = InvalidationTracker.Configuration.permissive
        XCTAssertEqual(config.maxDepth, 20)
        XCTAssertFalse(config.throwOnCycle)
        XCTAssertTrue(config.logWarnings)
    }

    // MARK: - CycleInfo Description

    func testCycleInfoDescription() throws {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: true, logWarnings: false))

        let token1 = try tracker.beginInvalidation(tag: usersTag, source: "mutation1")

        do {
            _ = try tracker.beginInvalidation(tag: usersTag, source: "mutation2")
            XCTFail("Should have thrown")
        } catch let error as InvalidationTracker.TrackerError {
            if case .cycleDetected(let info) = error {
                XCTAssertTrue(info.description.contains("Cycle detected"))
                XCTAssertTrue(info.description.contains("tag:users"))
            } else {
                XCTFail("Expected cycleDetected error")
            }
        }

        tracker.endInvalidation(token1)
    }

    // MARK: - Different Tags Don't Cycle

    func testDifferentTagsNoCycle() {
        let tracker = InvalidationTracker(configuration: .init(throwOnCycle: true, logWarnings: false))

        // Different tags should not trigger cycle detection
        let token1 = try! tracker.beginInvalidation(tag: usersTag)
        let token2 = try! tracker.beginInvalidation(tag: postsTag)
        let token3 = try! tracker.beginInvalidation(tag: commentsTag)

        XCTAssertFalse(token1.wasSkipped)
        XCTAssertFalse(token2.wasSkipped)
        XCTAssertFalse(token3.wasSkipped)
        XCTAssertEqual(tracker.stats.cyclesDetected, 0)

        tracker.endInvalidation(token3)
        tracker.endInvalidation(token2)
        tracker.endInvalidation(token1)
    }
}

// MARK: - Test Helpers

private enum CycleTestError: Error {
    case intentionalError
}

import Foundation

/// The status of a query's data
public enum QueryStatus: String, Sendable, Equatable {
    /// No query has been initiated
    case idle
    /// Query is fetching for the first time (no data yet)
    case pending
    /// Query completed successfully
    case success
    /// Query failed with an error
    case error
}

/// The fetch status of a query (separate from data status)
public enum FetchStatus: String, Sendable, Equatable {
    /// Not currently fetching
    case idle
    /// Currently fetching (initial or background)
    case fetching
    /// Fetch paused (e.g., due to network unavailability)
    case paused
}

/// Result enum for pattern matching in views
public enum QueryResult<T: Sendable>: Sendable {
    case idle
    case loading
    case success(T)
    case error(Error)
    
    public var data: T? {
        if case .success(let data) = self { return data }
        return nil
    }
    
    public var error: Error? {
        if case .error(let error) = self { return error }
        return nil
    }
}

/// Observable query state for SwiftUI integration.
///
/// This class tracks the complete state of a query, including:
/// - Current data (if any)
/// - Loading states (initial vs background refetch)
/// - Error states
/// - Timestamps
///
/// Use the computed properties for common state checks:
/// ```swift
/// if query.isLoading {
///     ProgressView()
/// } else if let data = query.data {
///     ContentView(data: data)
/// }
/// ```
@Observable
@MainActor
public final class QueryState<T: Sendable>: Sendable {
    // MARK: - Core State
    
    /// The latest successfully fetched data
    public private(set) var data: T?
    
    /// The latest error, if any
    public private(set) var error: Error?
    
    /// The status of the query data
    public private(set) var status: QueryStatus = .idle
    
    /// The status of the current/last fetch operation
    public private(set) var fetchStatus: FetchStatus = .idle
    
    /// When the data was last successfully updated
    public private(set) var dataUpdatedAt: Date?
    
    /// When an error last occurred
    public private(set) var errorUpdatedAt: Date?
    
    /// Number of times the query has failed consecutively
    public private(set) var failureCount: Int = 0
    
    // MARK: - Derived State (React Query style)
    
    /// True when status is pending (first-time load, no data)
    public var isPending: Bool { status == .pending }
    
    /// True when loading for the first time (pending + fetching)
    public var isLoading: Bool { isPending && isFetching }
    
    /// True when query completed successfully
    public var isSuccess: Bool { status == .success }
    
    /// True when query is in error state
    public var isError: Bool { status == .error }
    
    /// True when currently fetching
    public var isFetching: Bool { fetchStatus == .fetching }
    
    /// True when refetching in the background (have data + fetching)
    public var isRefetching: Bool { isSuccess && isFetching }
    
    /// True when fetch is paused
    public var isPaused: Bool { fetchStatus == .paused }
    
    /// True if we have stale data that's being refreshed
    public var isStale: Bool { isRefetching }
    
    /// True if data exists, regardless of staleness
    public var hasData: Bool { data != nil }
    
    // MARK: - Result for Pattern Matching
    
    /// Convenience for switch statements in views
    public var result: QueryResult<T> {
        switch status {
        case .idle:
            return .idle
        case .pending:
            return .loading
        case .success:
            if let data {
                return .success(data)
            }
            return .loading
        case .error:
            if let error {
                return .error(error)
            }
            return .idle
        }
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    public init(data: T) {
        self.data = data
        self.status = .success
        self.dataUpdatedAt = Date()
    }
    
    // MARK: - Internal State Updates
    
    func setData(_ data: T) {
        self.data = data
        self.status = .success
        self.dataUpdatedAt = Date()
        self.error = nil
        self.failureCount = 0
    }
    
    func setError(_ error: Error) {
        self.error = error
        self.errorUpdatedAt = Date()
        self.failureCount += 1
        // Only set status to error if we don't have data
        if data == nil {
            self.status = .error
        }
    }
    
    func setFetching(_ fetching: Bool) {
        self.fetchStatus = fetching ? .fetching : .idle
        if fetching && data == nil && status != .error {
            self.status = .pending
        }
    }
    
    func setPaused(_ paused: Bool) {
        self.fetchStatus = paused ? .paused : .idle
    }
    
    func reset() {
        self.data = nil
        self.error = nil
        self.status = .idle
        self.fetchStatus = .idle
        self.dataUpdatedAt = nil
        self.errorUpdatedAt = nil
        self.failureCount = 0
    }
}

// MARK: - Equatable for Value Types

extension QueryState: Equatable where T: Equatable {
    public static func == (lhs: QueryState<T>, rhs: QueryState<T>) -> Bool {
        lhs.data == rhs.data &&
        lhs.status == rhs.status &&
        lhs.fetchStatus == rhs.fetchStatus
    }
}

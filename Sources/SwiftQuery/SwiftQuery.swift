// SwiftQuery - React Query-inspired data fetching for Swift
//
// A declarative data fetching library with:
// - Tag-based hierarchical cache invalidation
// - GRDB-backed persistent storage
// - Swift Observation framework integration
// - SwiftUI-native APIs

// MARK: - Core Types

@_exported import Foundation

// Re-export all public types
public typealias QueryKey = SwiftQuery.QueryKey
public typealias QueryTag = SwiftQuery.QueryTag
public typealias QueryState = SwiftQuery.QueryState
public typealias QueryStatus = SwiftQuery.QueryStatus
public typealias FetchStatus = SwiftQuery.FetchStatus
public typealias QueryResult = SwiftQuery.QueryResult
public typealias QueryOptions = SwiftQuery.QueryOptions
public typealias QueryClient = SwiftQuery.QueryClient
public typealias QueryCache = SwiftQuery.QueryCache
public typealias QueryObserver = SwiftQuery.QueryObserver
public typealias MutationState = SwiftQuery.MutationState
public typealias CacheResult = SwiftQuery.CacheResult
public typealias CacheStats = SwiftQuery.CacheStats
public typealias CacheDatabaseConfiguration = SwiftQuery.CacheDatabaseConfiguration

import Foundation

/// Hierarchical tags enabling cascade invalidation.
///
/// Tags use a segment-based structure where invalidating a parent tag
/// automatically invalidates all child tags. For example, invalidating
/// `QueryTag("users")` will also invalidate `QueryTag("users", "123")`.
///
/// ```swift
/// let usersTag = QueryTag("users")
/// let userTag = QueryTag("users", "123")
/// let userPostsTag = QueryTag("users", "123", "posts")
///
/// usersTag.matches(userTag)      // true - parent matches child
/// usersTag.matches(userPostsTag) // true - ancestor matches descendant
/// userTag.matches(usersTag)      // false - child doesn't match parent
/// ```
public struct QueryTag: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let segments: [String]
    
    public init(_ segments: String...) {
        self.segments = segments
    }
    
    public init(segments: [String]) {
        self.segments = segments
    }
    
    public init(stringLiteral value: String) {
        self.segments = [value]
    }
    
    /// Returns true if self is a prefix of (or equal to) other.
    /// This enables cascade invalidation where invalidating a parent
    /// tag also invalidates all child tags.
    public func matches(_ other: QueryTag) -> Bool {
        guard segments.count <= other.segments.count else { return false }
        return segments.enumerated().allSatisfy { other.segments[$0.offset] == $0.element }
    }
    
    /// JSON representation for GRDB storage
    public var jsonEncoded: String {
        let data = try? JSONEncoder().encode(segments)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    
    public var description: String {
        segments.joined(separator: ".")
    }
}

// MARK: - Tag Set Utilities

extension Set where Element == QueryTag {
    /// Checks if any tag in this set matches the given tag (for invalidation)
    public func containsMatch(for tag: QueryTag) -> Bool {
        contains { tag.matches($0) }
    }

    /// JSON representation for GRDB storage
    /// Encodes all unique segments from all tags as a flat array for LIKE-based queries
    public var jsonEncoded: String {
        let allSegments: [String] = flatMap(\.segments)
        let uniqueSegments = Array(Set<String>(allSegments))
        let data = try? JSONEncoder().encode(uniqueSegments)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

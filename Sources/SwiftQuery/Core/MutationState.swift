import Foundation

/// The status of a mutation
public enum MutationStatus: String, Sendable, Equatable {
    case idle
    case pending
    case success
    case error
}

/// Observable mutation state for SwiftUI integration.
///
/// Mutations are used for create/update/delete operations that modify server state.
/// Unlike queries, mutations:
/// - Are not cached
/// - Must be explicitly triggered
/// - Can invalidate related queries after completion
///
/// ```swift
/// @State private var createPost = MutationState<CreatePostInput, Post>(
///     mutationFn: api.createPost,
///     invalidateTags: [.posts]
/// )
///
/// Button("Create") {
///     Task {
///         try await createPost.mutate(input)
///     }
/// }
/// .disabled(createPost.isPending)
/// ```
@Observable
@MainActor
public final class MutationState<Input: Sendable, Output: Sendable> {
    // MARK: - Core State
    
    /// The last successful mutation result
    public private(set) var data: Output?
    
    /// The last error, if any
    public private(set) var error: Error?
    
    /// The current status of the mutation
    public private(set) var status: MutationStatus = .idle
    
    /// The input variables of the current/last mutation (useful for optimistic UI)
    public private(set) var variables: Input?
    
    /// When the mutation was submitted
    public private(set) var submittedAt: Date?
    
    // MARK: - Derived State
    
    public var isIdle: Bool { status == .idle }
    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }
    
    // MARK: - Configuration
    
    private let mutationFn: @Sendable (Input) async throws -> Output
    private let invalidateTags: [QueryTag]
    private let onMutate: (@Sendable (Input) async -> Any?)?
    private let onSuccess: (@Sendable (Output, Input) async -> Void)?
    private let onError: (@Sendable (Error, Input, Any?) async -> Void)?
    private let onSettled: (@Sendable (Output?, Error?, Input) async -> Void)?
    
    // MARK: - Initialization
    
    public init(
        mutationFn: @escaping @Sendable (Input) async throws -> Output,
        invalidateTags: [QueryTag] = [],
        onMutate: (@Sendable (Input) async -> Any?)? = nil,
        onSuccess: (@Sendable (Output, Input) async -> Void)? = nil,
        onError: (@Sendable (Error, Input, Any?) async -> Void)? = nil,
        onSettled: (@Sendable (Output?, Error?, Input) async -> Void)? = nil
    ) {
        self.mutationFn = mutationFn
        self.invalidateTags = invalidateTags
        self.onMutate = onMutate
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
    }
    
    // MARK: - Mutation Execution
    
    /// Execute the mutation with the given input
    @discardableResult
    public func mutate(_ input: Input) async throws -> Output {
        variables = input
        status = .pending
        submittedAt = Date()
        
        // onMutate callback (for optimistic updates, returns context for rollback)
        let context = await onMutate?(input)
        
        do {
            let result = try await mutationFn(input)
            
            data = result
            error = nil
            status = .success
            
            // onSuccess callback
            await onSuccess?(result, input)
            
            // Invalidate related queries
            for tag in invalidateTags {
                await QueryClient.shared.invalidate(tag: tag)
            }
            
            // onSettled callback
            await onSettled?(result, nil, input)
            
            return result
        } catch {
            self.error = error
            status = .error
            
            // onError callback (with context for rollback)
            await onError?(error, input, context)
            
            // onSettled callback
            await onSettled?(nil, error, input)
            
            throw error
        }
    }
    
    /// Reset the mutation state
    public func reset() {
        data = nil
        error = nil
        status = .idle
        variables = nil
        submittedAt = nil
    }
}

// MARK: - Convenience Initializers

extension MutationState where Input == Void {
    /// Convenience for mutations with no input
    public func mutate() async throws -> Output {
        try await mutate(())
    }
}

// MARK: - Mutation Builder

/// Builder for creating mutations with configuration
public struct MutationBuilder<Input: Sendable, Output: Sendable> {
    private var mutationFn: (@Sendable (Input) async throws -> Output)?
    private var invalidateTags: [QueryTag] = []
    private var onMutate: (@Sendable (Input) async -> Any?)?
    private var onSuccess: (@Sendable (Output, Input) async -> Void)?
    private var onError: (@Sendable (Error, Input, Any?) async -> Void)?
    private var onSettled: (@Sendable (Output?, Error?, Input) async -> Void)?
    
    public init() {}
    
    public func mutationFn(_ fn: @escaping @Sendable (Input) async throws -> Output) -> Self {
        var copy = self
        copy.mutationFn = fn
        return copy
    }
    
    public func invalidates(_ tags: QueryTag...) -> Self {
        var copy = self
        copy.invalidateTags = tags
        return copy
    }
    
    public func onMutate(_ handler: @escaping @Sendable (Input) async -> Any?) -> Self {
        var copy = self
        copy.onMutate = handler
        return copy
    }
    
    public func onSuccess(_ handler: @escaping @Sendable (Output, Input) async -> Void) -> Self {
        var copy = self
        copy.onSuccess = handler
        return copy
    }
    
    public func onError(_ handler: @escaping @Sendable (Error, Input, Any?) async -> Void) -> Self {
        var copy = self
        copy.onError = handler
        return copy
    }
    
    public func onSettled(_ handler: @escaping @Sendable (Output?, Error?, Input) async -> Void) -> Self {
        var copy = self
        copy.onSettled = handler
        return copy
    }
    
    @MainActor
    public func build() -> MutationState<Input, Output> {
        guard let mutationFn else {
            fatalError("MutationBuilder requires a mutationFn")
        }
        return MutationState(
            mutationFn: mutationFn,
            invalidateTags: invalidateTags,
            onMutate: onMutate,
            onSuccess: onSuccess,
            onError: onError,
            onSettled: onSettled
        )
    }
}

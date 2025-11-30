import SwiftUI

/// Property wrapper for declarative mutations in SwiftUI.
///
/// `@Mutation` provides a way to perform create/update/delete operations
/// with automatic cache invalidation.
///
/// ```swift
/// struct CreatePostView: View {
///     @Mutation(invalidates: .posts) { input in
///         try await api.createPost(input)
///     } var createPost
///
///     var body: some View {
///         Button("Create") {
///             Task {
///                 try await createPost.mutate(CreatePostInput(title: title))
///             }
///         }
///         .disabled(createPost.isPending)
///     }
/// }
/// ```
@propertyWrapper
@MainActor
public struct Mutation<Input: Sendable, Output: Sendable>: @preconcurrency DynamicProperty {
    @State private var state: MutationState<Input, Output>
    
    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @Sendable (Input) async throws -> Output
    ) {
        self._state = State(
            initialValue: MutationState(
                mutationFn: mutationFn,
                invalidateTags: tags
            )
        )
    }
    
    public init(
        invalidates tags: [QueryTag] = [],
        onMutate: (@Sendable (Input) async -> Any?)? = nil,
        onSuccess: (@Sendable (Output, Input) async -> Void)? = nil,
        onError: (@Sendable (Error, Input, Any?) async -> Void)? = nil,
        onSettled: (@Sendable (Output?, Error?, Input) async -> Void)? = nil,
        mutationFn: @escaping @Sendable (Input) async throws -> Output
    ) {
        self._state = State(
            initialValue: MutationState(
                mutationFn: mutationFn,
                invalidateTags: tags,
                onMutate: onMutate,
                onSuccess: onSuccess,
                onError: onError,
                onSettled: onSettled
            )
        )
    }
    
    public var wrappedValue: MutationState<Input, Output> {
        state
    }
    
    public var projectedValue: MutationActions<Input, Output> {
        MutationActions(state: state)
    }
}

// MARK: - Mutation Actions

/// Actions available via the projected value ($mutation)
@MainActor
public struct MutationActions<Input: Sendable, Output: Sendable> {
    fileprivate let state: MutationState<Input, Output>
    
    /// Execute the mutation
    @discardableResult
    public func mutate(_ input: Input) async throws -> Output {
        try await state.mutate(input)
    }
    
    /// Reset the mutation state
    public func reset() {
        state.reset()
    }
}

// MARK: - Void Input Convenience

extension Mutation where Input == Void {
    /// Initialize a mutation with no input
    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @Sendable () async throws -> Output
    ) {
        self._state = State(
            initialValue: MutationState(
                mutationFn: { _ in try await mutationFn() },
                invalidateTags: tags
            )
        )
    }
}

extension MutationActions where Input == Void {
    /// Execute a mutation with no input
    @discardableResult
    public func mutate() async throws -> Output {
        try await state.mutate(())
    }
}

// MARK: - UseMutation View

/// Functional approach to using mutations in views
@MainActor
public struct UseMutation<Input: Sendable, Output: Sendable, Content: View>: View {
    @State private var mutation: MutationState<Input, Output>
    let content: (MutationState<Input, Output>) -> Content
    
    public init(
        invalidates tags: [QueryTag] = [],
        mutationFn: @escaping @Sendable (Input) async throws -> Output,
        @ViewBuilder content: @escaping (MutationState<Input, Output>) -> Content
    ) {
        self._mutation = State(
            initialValue: MutationState(
                mutationFn: mutationFn,
                invalidateTags: tags
            )
        )
        self.content = content
    }
    
    public var body: some View {
        content(mutation)
    }
}

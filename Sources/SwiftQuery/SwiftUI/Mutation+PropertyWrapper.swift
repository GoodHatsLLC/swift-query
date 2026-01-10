#if canImport(SwiftUI)
import SwiftUI

/// Property wrapper for declarative mutations in SwiftUI.
///
/// `@Mutation` provides a way to perform create/update/delete operations
/// with automatic cache invalidation.
///
/// If you accept an `EnvironmentValues` parameter, you can read app-defined
/// dependencies you've injected into SwiftUI's environment (e.g. `env.apiClient`).
///
/// ```swift
/// struct CreatePostView: View {
///     @Mutation(invalidates: .posts) { env, input in
///         try await env.apiClient.createPost(input)
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
    @Environment(\.queryClient) private var client
    @Environment(\.self) private var env
    @State private var state: MutationState<Input, Output>

    private let envBox: MutationEnvironmentBox

    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @MainActor (Input) async throws -> Output
    ) {
        self.init(
            invalidates: tags,
            mutationFn: { _, input in
                try await mutationFn(input)
            }
        )
    }

    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @MainActor (_ env: EnvironmentValues, _ input: Input) async throws -> Output
    ) {
        self.init(invalidates: Array(tags), mutationFn: mutationFn)
    }

    public init(
        invalidates tags: [QueryTag] = [],
        onMutate: (@MainActor (Input) async -> Any?)? = nil,
        onSuccess: (@MainActor (Output, Input) async -> Void)? = nil,
        onError: (@MainActor (Error, Input, Any?) async -> Void)? = nil,
        onSettled: (@MainActor (Output?, Error?, Input) async -> Void)? = nil,
        mutationFn: @escaping @MainActor (Input) async throws -> Output
    ) {
        self.init(
            invalidates: tags,
            onMutate: onMutate,
            onSuccess: onSuccess,
            onError: onError,
            onSettled: onSettled,
            mutationFn: { _, input in
                try await mutationFn(input)
            }
        )
    }

    public init(
        invalidates tags: [QueryTag] = [],
        onMutate: (@MainActor (Input) async -> Any?)? = nil,
        onSuccess: (@MainActor (Output, Input) async -> Void)? = nil,
        onError: (@MainActor (Error, Input, Any?) async -> Void)? = nil,
        onSettled: (@MainActor (Output?, Error?, Input) async -> Void)? = nil,
        mutationFn: @escaping @MainActor (_ env: EnvironmentValues, _ input: Input) async throws -> Output
    ) {
        let envBox = MutationEnvironmentBox()
        self.envBox = envBox
        self._state = State(
            initialValue: MutationState(
                mutationFn: { input in
                    guard let env = envBox.env?.value else {
                        preconditionFailure("@Mutation used before SwiftUI environment is available.")
                    }
                    return try await mutationFn(env, input)
                },
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

    public func update() {
        envBox.env = Transferring(env)
        state.attach(client: client)
    }
}

// MARK: - Mutation Actions

/// Actions available via the projected value ($mutation)
@MainActor
public struct MutationActions<Input: Sendable, Output: Sendable> {
    fileprivate let state: MutationState<Input, Output>

    public init(state: MutationState<Input, Output>) {
        self.state = state
    }
    
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
        mutationFn: @escaping @MainActor () async throws -> Output
    ) {
        self.init(
            invalidates: tags,
            mutationFn: { _, _ in try await mutationFn() }
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

@MainActor
private final class MutationEnvironmentBox {
    var env: Transferring<EnvironmentValues>?
}
#endif

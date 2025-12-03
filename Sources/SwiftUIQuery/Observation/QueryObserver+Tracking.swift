#if canImport(Observation)
import Observation
import Foundation

extension QueryObserver {
    /// Register an Observation listener for a derived value of this observer.
    ///
    /// - Parameters:
    ///   - read: Closure that reads observable state. This will be executed
    ///     immediately to register dependencies.
    ///   - onChange: Called whenever any of the read properties change.
    /// - Returns: The value returned by `read` for convenience.
    @discardableResult
    public func track<T>(
        _ read: () -> T,
        onChange: @Sendable @escaping () -> Void
    ) -> T {
        withObservationTracking(read, onChange: onChange)
    }
}
#endif

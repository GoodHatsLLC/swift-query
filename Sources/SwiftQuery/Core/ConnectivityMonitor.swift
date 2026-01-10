import Dispatch
import Foundation

#if canImport(Network)
import Network
#endif

/// Emits network connectivity changes used for automatic refetch behavior.
public actor ConnectivityMonitor: Sendable {
    public enum Status: Sendable, Equatable {
        case satisfied
        case unsatisfied
    }

    public static let shared = ConnectivityMonitor()

    private var status: Status
    private var continuations: [UUID: AsyncStream<Status>.Continuation] = [:]

    #if canImport(Network)
    nonisolated private let monitor: NWPathMonitor?
    #endif

    public init(startMonitoring: Bool = true, initialStatus: Status = .satisfied) {
        self.status = initialStatus

        #if canImport(Network)
        if startMonitoring {
            let monitor = NWPathMonitor()
            self.monitor = monitor

            monitor.pathUpdateHandler = { [weak self] path in
                let mapped: Status = (path.status == .satisfied) ? .satisfied : .unsatisfied
                Task { await self?.updateStatus(mapped) }
            }

            monitor.start(queue: DispatchQueue(label: "SwiftQuery.ConnectivityMonitor"))
        } else {
            self.monitor = nil
        }
        #endif
    }

    deinit {
        #if canImport(Network)
        monitor?.cancel()
        #endif
    }

    public func statuses() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation

            // Yield the current status immediately so consumers can track transitions.
            continuation.yield(status)

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func currentStatus() -> Status {
        status
    }

    internal func setStatusForTesting(_ newStatus: Status) {
        updateStatus(newStatus)
    }

    private func updateStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus

        for continuation in continuations.values {
            continuation.yield(newStatus)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Emits app lifecycle events used for automatic refetch behavior.
///
/// This is intentionally SwiftUI-free so it can be used by `QueryObserver` and
/// tests without requiring SwiftUI.
public actor AppLifecycleMonitor: Sendable {
    public enum Event: Sendable, Equatable {
        case didBecomeActive
    }

    public static let shared = AppLifecycleMonitor()

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private let observerBag = ObserverBag()
    private let shouldObserveSystemNotifications: Bool

    public init(observeSystemNotifications: Bool = true) {
        self.shouldObserveSystemNotifications = observeSystemNotifications

        if observeSystemNotifications {
            Task { await installSystemObserversIfNeeded() }
        }
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    internal func emitForTesting(_ event: Event) {
        emit(event)
    }

    internal func ensureSystemObserversInstalledForTesting() async {
        await installSystemObserversIfNeeded()
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func installSystemObserversIfNeeded() async {
        guard shouldObserveSystemNotifications else { return }

        let center = NotificationCenter.default

        #if canImport(UIKit)
        observerBag.add(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.emit(.didBecomeActive) }
            }
        )
        #endif

        #if canImport(AppKit)
        observerBag.add(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.emit(.didBecomeActive) }
            }
        )
        #endif
    }
}

private final class ObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

import Foundation

/// Home, Work and other places, detected on-device from recent history (see Shared/Places.swift).
@MainActor
final class PlaceCache: ObservableObject {
    static let shared = PlaceCache()

    @Published private(set) var places: [Place] = []
    private var lastRefresh = Date.distantPast
    private var running = false

    /// Recomputes at most every 10 minutes unless forced. Uses the last 180 days.
    func refresh(force: Bool = false) {
        guard !running, force || Date().timeIntervalSince(lastRefresh) > 600 else { return }
        running = true
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            let store = PointStore.shared
            let days = store.dayKeys().suffix(180).map { store.points(dayKey: $0) }
            let detected = Places.detect(days: Array(days))
            await MainActor.run {
                PlaceCache.shared.places = detected
                PlaceCache.shared.running = false
            }
        }
    }

    func place(for segment: Segment, points: [TrackPoint]) -> Place? {
        Places.place(for: segment, points: points, in: places)
    }
}

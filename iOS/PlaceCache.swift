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
            let keys = store.dayKeys().suffix(180)
            let days = keys.map { store.points(dayKey: $0) }
            let from = keys.first.flatMap(PointStore.date(fromDayKey:)) ?? Date()
            let motion = MotionStore.shared.spans(from: from, to: Date())
            let detected = Places.detect(days: Array(days), motion: motion)
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

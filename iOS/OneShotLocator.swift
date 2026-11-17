import CoreLocation

/// One good GPS fix, using its own location manager so it doesn't disturb continuous recording.
/// Waits for ±20 m (or ±50 m after 10 s) and otherwise returns the best fix seen by the timeout.
final class OneShotLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var started = Date()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timer: Timer?
    private var keepAlive: OneShotLocator?

    @MainActor
    func locate(timeout: TimeInterval) async -> CLLocation? {
        await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            continuation = c
            keepAlive = self
            started = Date()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
            if manager.authorizationStatus == .authorizedAlways {
                manager.allowsBackgroundLocationUpdates = true
                manager.showsBackgroundLocationIndicator = false
            }
            manager.startUpdatingLocation()
            timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in self?.finish() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.timestamp >= started.addingTimeInterval(-5) {
            if best.map({ loc.horizontalAccuracy < $0.horizontalAccuracy }) ?? true { best = loc }
        }
        guard let best else { return }
        let waited = Date().timeIntervalSince(started)
        if best.horizontalAccuracy <= 20 || (waited > 10 && best.horizontalAccuracy <= 50) { finish() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { finish() }
    }

    private func finish() {
        guard let c = continuation else { return }
        continuation = nil
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        c.resume(returning: best)
        keepAlive = nil
    }
}

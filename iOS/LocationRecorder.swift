import Foundation
import CoreLocation
import CoreMotion

/// Records GPS fixes in the foreground and background and tags each one with what the
/// motion coprocessor thinks you're doing.
///
/// GPS works without any network, so this keeps working in airplane mode. Planes are detected
/// later from speed/altitude (the accelerometer often thinks a smooth flight is "stationary").
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationRecorder()

    enum PowerMode: String, CaseIterable, Identifiable {
        case smart, precise
        var id: String { rawValue }
        var title: String {
            switch self {
            case .smart: return "Smart"
            case .precise: return "Always precise"
            }
        }
    }

    private enum Keys {
        static let recording = "recorder.isRecording"
        static let power = "recorder.powerMode"
    }

    @Published private(set) var isRecording: Bool
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var preciseAllowed = true
    @Published private(set) var lastPoint: TrackPoint?
    @Published private(set) var currentActivity: ActivityType = .unknown
    @Published private(set) var todayCount = 0
    @Published private(set) var isLowPower = false
    @Published var powerMode: PowerMode {
        didSet {
            defaults.set(powerMode.rawValue, forKey: Keys.power)
            if powerMode == .precise { isLowPower = false }
            applyAccuracy()
        }
    }

    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let defaults = UserDefaults.standard
    private let store = PointStore.shared
    private var countDayKey = ""
    private var lastFastFix = Date.distantPast

    private override init() {
        isRecording = UserDefaults.standard.bool(forKey: Keys.recording)
        powerMode = PowerMode(rawValue: UserDefaults.standard.string(forKey: Keys.power) ?? "") ?? .smart
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        preciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        lastPoint = store.lastPoint()
        refreshTodayCount()
        if isRecording { beginUpdates() }
    }

    // MARK: Control

    func start() {
        isRecording = true
        defaults.set(true, forKey: Keys.recording)
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        beginUpdates()
    }

    func stop() {
        isRecording = false
        defaults.set(false, forKey: Keys.recording)
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        motion.stopActivityUpdates()
        manager.allowsBackgroundLocationUpdates = false
        isLowPower = false
    }

    func refreshTodayCount() {
        countDayKey = PointStore.dayKey(Date())
        todayCount = store.count(dayKey: countDayKey)
    }

    private func beginUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false   // never let iOS silently stop us
        manager.showsBackgroundLocationIndicator = false
        manager.activityType = .other
        isLowPower = false
        applyAccuracy()
        manager.startUpdatingLocation()
        // Lets iOS relaunch the app after it was killed (e.g. phone restart) once you move ~500 m.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        startMotion()
    }

    private func applyAccuracy() {
        if isLowPower && powerMode == .smart {
            // Standing still: let the GPS chip sleep.
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = powerMode == .precise ? 5 : 15
        }
    }

    private func setLowPower(_ low: Bool) {
        guard low != isLowPower else { return }
        isLowPower = low
        applyAccuracy()
    }

    // MARK: Motion

    private func startMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.handle(activity)
        }
    }

    private func handle(_ activity: CMMotionActivity) {
        guard activity.confidence != .low else { return }
        let type = ActivityType(motion: activity)
        guard type != .unknown else { return }
        currentActivity = type
        if type == .stationary {
            // Don't power down if we were just doing airliner speeds: smooth flight feels "stationary".
            let recentlyFast = Date().timeIntervalSince(lastFastFix) < 10 * 60
            if powerMode == .smart && !recentlyFast { setLowPower(true) }
        } else {
            setLowPower(false)
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        for loc in locations { record(loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient (e.g. no GPS signal inside a plane); just keep going.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        preciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        if isRecording && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) {
            beginUpdates()
        }
    }

    private func record(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 200 else { return }
        if let last = lastPoint, loc.timestamp <= last.t { return }

        let point = TrackPoint(
            t: loc.timestamp,
            lat: Self.round(loc.coordinate.latitude, 6),
            lon: Self.round(loc.coordinate.longitude, 6),
            alt: loc.verticalAccuracy > 0 ? Self.round(loc.altitude, 1) : nil,
            acc: Self.round(loc.horizontalAccuracy, 1),
            spd: loc.speed >= 0 ? Self.round(loc.speed, 2) : nil,
            crs: loc.course >= 0 ? Self.round(loc.course, 0) : nil,
            act: currentActivity == .unknown ? nil : currentActivity
        )
        store.append(point)
        lastPoint = point

        if PointStore.dayKey(point.t) == countDayKey {
            todayCount += 1
        } else {
            refreshTodayCount()
        }

        if loc.speed > 30 { lastFastFix = loc.timestamp }
        if isLowPower && loc.speed > 3 { setLowPower(false) }
    }

    private static func round(_ x: Double, _ digits: Int) -> Double {
        let m = pow(10, Double(digits))
        return (x * m).rounded() / m
    }
}

extension ActivityType {
    init(motion a: CMMotionActivity) {
        if a.automotive { self = .driving }          // also true when stopped in a car
        else if a.cycling { self = .cycling }
        else if a.running { self = .running }
        else if a.walking { self = .walking }
        else if a.stationary { self = .stationary }
        else { self = .unknown }
    }
}

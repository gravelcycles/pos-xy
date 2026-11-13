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
        static let interval = "recorder.intervalSeconds"
    }

    /// "Record a point" presets, in seconds. 0 = continuously (every ~15 m moved).
    static let intervalPresets = [0, 60, 300, 900, 3600]
    /// Allowed range for a custom interval: 10 seconds to 12 hours.
    static let customIntervalRange = 10...43_200

    @Published private(set) var isRecording: Bool
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var preciseAllowed = true
    @Published private(set) var lastPoint: TrackPoint?
    @Published private(set) var currentActivity: ActivityType = .unknown
    @Published private(set) var todayCount = 0
    @Published private(set) var isLowPower = false
    /// Seconds between recorded points; 0 = continuous.
    @Published var interval: Int {
        didSet {
            let clamped = interval == 0 ? 0 : min(max(interval, Self.customIntervalRange.lowerBound),
                                                    Self.customIntervalRange.upperBound)
            if clamped != interval { interval = clamped }   // assigning inside didSet doesn't re-trigger it
            defaults.set(interval, forKey: Keys.interval)
            if isRecording { configureSchedule() }
        }
    }
    /// When the next timed point will be taken (interval mode only).
    @Published private(set) var nextPointAt: Date?
    /// True while the GPS is on to take a timed point.
    @Published private(set) var isTakingPoint = false
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
    // Interval mode
    private var tickTimer: Timer?
    private var pointStartedAt: Date?
    private var bestCandidate: CLLocation?

    private override init() {
        isRecording = UserDefaults.standard.bool(forKey: Keys.recording)
        powerMode = PowerMode(rawValue: UserDefaults.standard.string(forKey: Keys.power) ?? "") ?? .smart
        interval = max(0, UserDefaults.standard.integer(forKey: Keys.interval))
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
        stopSchedule()
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
        configureSchedule()
        // Lets iOS relaunch the app after it was killed (e.g. phone restart) once you move ~500 m.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        startMotion()
    }

    private func applyAccuracy() {
        if interval > 0 {
            if isTakingPoint {
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone
            } else {
                // Between timed points: GPS off. This coarse session costs almost nothing but keeps
                // iOS running the app in the background so the next point happens on time.
                manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
                manager.distanceFilter = CLLocationDistanceMax
            }
            return
        }
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
        guard interval == 0, low != isLowPower else { return }
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
        if interval > 0 {
            for loc in locations { consider(loc) }
        } else {
            for loc in locations { record(loc) }
        }
    }

    // MARK: Interval mode ("Record a point every N minutes")

    private func configureSchedule() {
        stopSchedule()
        guard isRecording, interval > 0 else {
            applyAccuracy()
            return
        }
        isLowPower = false
        nextPointAt = Date()                       // take the first point right away
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    private func stopSchedule() {
        tickTimer?.invalidate()
        tickTimer = nil
        pointStartedAt = nil
        bestCandidate = nil
        isTakingPoint = false
        nextPointAt = nil
    }

    /// How long to keep the GPS on waiting for a good fix. Cold starts without a network
    /// (airplane mode) can be slow.
    private var pointTimeout: TimeInterval { min(90, max(20, Double(interval) / 2)) }

    private func tick() {
        let now = Date()
        if let started = pointStartedAt {
            if now.timeIntervalSince(started) >= pointTimeout { finishPoint() }
        } else if let due = nextPointAt, now >= due {
            pointStartedAt = now
            bestCandidate = nil
            isTakingPoint = true
            applyAccuracy()
        }
    }

    private func consider(_ loc: CLLocation) {
        guard let started = pointStartedAt, loc.horizontalAccuracy >= 0,
              loc.timestamp >= started.addingTimeInterval(-2) else { return }   // ignore stale/cached fixes
        if bestCandidate.map({ loc.horizontalAccuracy < $0.horizontalAccuracy }) ?? true {
            bestCandidate = loc
        }
        let waited = Date().timeIntervalSince(started)
        if loc.horizontalAccuracy <= 20 || (waited > 10 && loc.horizontalAccuracy <= 50) {
            finishPoint()
        }
    }

    private func finishPoint() {
        if let best = bestCandidate { record(best) }    // record() still drops fixes worse than 200 m
        let started = pointStartedAt ?? Date()
        pointStartedAt = nil
        bestCandidate = nil
        isTakingPoint = false
        nextPointAt = max(started.addingTimeInterval(TimeInterval(interval)), Date().addingTimeInterval(5))
        applyAccuracy()
    }

    static func describe(interval: Int) -> String {
        switch interval {
        case 0: return "Continuously"
        case 60: return "Every minute"
        case 3600: return "Every hour"
        default:
            if interval % 3600 == 0 { return "Every \(interval / 3600) hours" }
            if interval % 60 == 0 { return "Every \(interval / 60) minutes" }
            return "Every \(interval) seconds"
        }
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
            crs: loc.course >= 0 ? Self.round(loc.course, 0).truncatingRemainder(dividingBy: 360) : nil,
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

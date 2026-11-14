import Foundation
import CoreLocation
import CoreMotion
import UIKit

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
        static let pausedUntil = "recorder.pausedUntil"
        static let motionBackfilledUntil = "motion.backfilledUntil"
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
    /// While set and in the future, nothing is recorded (privacy pause).
    @Published private(set) var pausedUntil: Date?
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
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
    // Keeps background location alive (iOS 17+); held while recording.
    private var backgroundSession: CLBackgroundActivitySession?
    // Rolling geofence: a circle around the last point. Leaving it makes iOS relaunch the app
    // even after it was killed, after ~150 m of movement instead of ~500 m for significant changes.
    private static let rollingRegionID = "posxy.rolling"
    private static let rollingRadius: CLLocationDistance = 150
    private var rollingCenter: CLLocation?
    // Motion-history backfill
    private var backfillRunning = false
    private var lastBackfillAttempt = Date.distantPast
    // Diagnostics (no coordinates are logged).
    private let diag = Diagnostics.shared
    private var lastDelivery: Date?
    private var lastLoggedAccuracy = ""
    private var stats = DeliveryStats()

    private struct DeliveryStats {
        var since = Date()
        var batches = 0, backgroundBatches = 0, recorded = 0
        var droppedAccuracy = 0, droppedStale = 0, droppedPaused = 0
        var bestAccuracy = Double.infinity, worstAccuracy = 0.0
    }

    private override init() {
        isRecording = UserDefaults.standard.bool(forKey: Keys.recording)
        powerMode = PowerMode(rawValue: UserDefaults.standard.string(forKey: Keys.power) ?? "") ?? .smart
        interval = max(0, UserDefaults.standard.integer(forKey: Keys.interval))
        let paused = UserDefaults.standard.object(forKey: Keys.pausedUntil) as? Date
        pausedUntil = (paused ?? .distantPast) > Date() ? paused : nil
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        preciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        lastPoint = store.lastPoint()
        refreshTodayCount()
        diag.log("recorder", "Init: recording \(isRecording ? "ON" : "off"), \(Self.describe(interval: interval).lowercased()), "
                 + "GPS mode \(powerMode.rawValue), permission \(Self.describe(authorization)), "
                 + "precise \(preciseAllowed ? "on" : "OFF")\(isPaused ? ", paused" : "").")
        if let last = lastPoint {
            diag.log("recorder", "Last stored point is \(Diagnostics.duration(Date().timeIntervalSince(last.t))) old.")
        }
        if isRecording {
            beginUpdates()
            backfillMotion(reason: "launch")
        }
        WidgetSync.publish(widgetStatus, force: true)
    }

    // MARK: Control

    func start() {
        diag.log("recorder", "Start pressed.")
        isRecording = true
        defaults.set(true, forKey: Keys.recording)
        switch manager.authorizationStatus {
        case .notDetermined:
            // Two steps on purpose. Asking for Always up front only gets "Allow While Using App"
            // plus a provisional upgrade that iOS offers hours later, in the background, if ever.
            // Asking for While Using first lets locationManagerDidChangeAuthorization ask for
            // Always the moment it's granted, and iOS then shows "Change to Always Allow" at once.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()   // iOS shows the upgrade prompt only once per install
        default:
            break
        }
        beginUpdates()
        WidgetSync.publish(widgetStatus, force: true)
    }

    func stop() {
        diag.log("recorder", "Stop pressed.")
        isRecording = false
        defaults.set(false, forKey: Keys.recording)
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        motion.stopActivityUpdates()
        manager.allowsBackgroundLocationUpdates = false
        manager.stopMonitoringVisits()
        stopRollingRegion()
        backgroundSession?.invalidate()
        backgroundSession = nil
        isLowPower = false
        pausedUntil = nil
        defaults.removeObject(forKey: Keys.pausedUntil)
        stopSchedule()
        WidgetSync.publish(widgetStatus, force: true)
    }

    func refreshTodayCount() {
        countDayKey = PointStore.dayKey(Date())
        todayCount = store.count(dayKey: countDayKey)
        WidgetSync.publish(widgetStatus, force: false)
    }

    /// What the Lock Screen widgets and Control Center controls show (no coordinates).
    var widgetStatus: RecordingStatus {
        RecordingStatus(isRecording: isRecording,
                        pausedUntil: isPaused ? pausedUntil : nil,
                        dayKey: countDayKey,
                        pointsToday: todayCount,
                        lastFix: lastPoint?.t,
                        intervalSeconds: interval)
    }

    private func beginUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false   // never let iOS silently stop us
        // With only "While Using" permission, iOS keeps background updates going only while the
        // blue location pill is shown; with Always it's not needed.
        manager.showsBackgroundLocationIndicator = manager.authorizationStatus != .authorizedAlways
        manager.activityType = .other
        // iOS 17+: an explicit background-activity session keeps location delivery alive while the
        // app isn't on screen. Created here (usually in the foreground) and held until Stop.
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        isLowPower = false
        applyAccuracy()
        manager.startUpdatingLocation()
        configureSchedule()
        // Both of these let iOS relaunch the app after it was killed (memory pressure, reboot):
        // significant changes after ~500 m of movement, visits when you arrive or leave a place.
        // They only work with Always permission.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        startMotion()
        let geofence = manager.authorizationStatus == .authorizedAlways
            && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        diag.log("recorder", "Updates started (permission \(Self.describe(manager.authorizationStatus)), "
                 + "background indicator \(manager.showsBackgroundLocationIndicator ? "on" : "off"), "
                 + "rolling geofence \(geofence ? "on" : "off: needs Always")).")
    }

    private func applyAccuracy() {
        defer { logAccuracyIfChanged() }
        if isPaused {
            // Paused: no GPS. The coarse session keeps the app alive so it can resume on time.
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            manager.distanceFilter = CLLocationDistanceMax
            return
        }
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
        diag.log("power", low ? "Standing still: GPS resting (100 m accuracy)." : "Moving again: GPS back to full accuracy.")
        applyAccuracy()
    }

    private func logAccuracyIfChanged() {
        let acc = manager.desiredAccuracy
        let accText: String
        switch acc {
        case kCLLocationAccuracyBest: accText = "best"
        case kCLLocationAccuracyBestForNavigation: accText = "navigation"
        case kCLLocationAccuracyNearestTenMeters: accText = "10 m"
        case kCLLocationAccuracyHundredMeters: accText = "100 m"
        case kCLLocationAccuracyKilometer: accText = "1 km"
        case kCLLocationAccuracyThreeKilometers: accText = "3 km (GPS off)"
        default: accText = "\(acc) m"
        }
        let filter = manager.distanceFilter == CLLocationDistanceMax ? "max" : "\(Int(manager.distanceFilter)) m"
        let text = "accuracy \(accText), distance filter \(filter)"
        guard text != lastLoggedAccuracy else { return }
        lastLoggedAccuracy = text
        diag.log("gps", "Now \(text).")
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
        if type != currentActivity { diag.log("motion", "Activity: \(type.rawValue).") }
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
        noteDelivery(locations)
        guard isRecording else { return }
        if isPaused { stats.droppedPaused += locations.count; return }
        if interval > 0 {
            for loc in locations { consider(loc) }
        } else {
            for loc in locations { record(loc) }
        }
    }

    // MARK: Motion-history backfill

    /// Saves the motion coprocessor's activity history since the last backfill (iOS keeps 7 days,
    /// recorded even while Pos XY wasn't running). The viewers use it to label gaps with no points.
    func backfillMotion(reason: String) {
        guard isRecording, CMMotionActivityManager.isActivityAvailable(), !backfillRunning else { return }
        let now = Date()
        let floor = now.addingTimeInterval(-7 * 86_400 + 600)
        let from = max((defaults.object(forKey: Keys.motionBackfilledUntil) as? Date) ?? floor, floor)
        lastBackfillAttempt = now
        guard now.timeIntervalSince(from) > 300 else { return }
        backfillRunning = true
        motion.queryActivityStarting(from: from, to: now, to: .main) { [weak self] activities, error in
            guard let self else { return }
            self.backfillRunning = false
            if let error {
                self.diag.log("motion", "History query failed: \(error.localizedDescription)")
                return
            }
            let (spans, until) = Self.spans(from: activities ?? [])
            MotionStore.shared.append(spans)
            if let until { self.defaults.set(until, forKey: Keys.motionBackfilledUntil) }
            let moving = spans.filter { MotionSpans.moving.contains($0.act) }
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            self.diag.log("motion", "History backfill (\(reason)): \(spans.count) spans covering "
                          + "\(Diagnostics.duration(now.timeIntervalSince(from))), \(Diagnostics.duration(moving)) of movement.")
        }
    }

    /// Turns raw activity samples into spans. Sample i lasts until sample i+1 starts; the last one is
    /// still going, so it's left for the next backfill (which starts from its start date).
    static func spans(from activities: [CMMotionActivity]) -> ([MotionSpan], Date?) {
        guard activities.count >= 2 else { return ([], nil) }
        var out: [MotionSpan] = []
        for i in 0..<(activities.count - 1) {
            let a = activities[i]
            let end = activities[i + 1].startDate
            guard a.confidence != .low, end > a.startDate else { continue }
            let type = ActivityType(motion: a)
            guard type != .unknown else { continue }
            if let last = out.last, last.act == type, abs(last.end.timeIntervalSince(a.startDate)) < 1 {
                out[out.count - 1].end = end
            } else {
                out.append(MotionSpan(start: a.startDate, end: end, act: type))
            }
        }
        return (out, activities.last?.startDate)
    }

    // MARK: Rolling geofence

    /// Moves the geofence to `loc` once we've drifted more than half its radius from its centre.
    private func updateRollingRegion(around loc: CLLocation, force: Bool = false) {
        guard isRecording, manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if !force, let c = rollingCenter, loc.distance(from: c) < Self.rollingRadius / 2 { return }
        let region = CLCircularRegion(center: loc.coordinate, radius: Self.rollingRadius, identifier: Self.rollingRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)          // same identifier replaces the previous circle
        if rollingCenter == nil { diag.log("geofence", "Armed (\(Int(Self.rollingRadius)) m around the latest point).") }
        rollingCenter = loc
    }

    private func stopRollingRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.rollingRegionID {
            manager.stopMonitoring(for: region)
        }
        rollingCenter = nil
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.rollingRegionID else { return }
        diag.heartbeat()
        diag.log("geofence", "Left the \(Int(Self.rollingRadius)) m geofence: iOS woke the app.")
        rollingCenter = nil                            // re-arm around the next fix
        setLowPower(false)                             // we're clearly moving
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.rollingRegionID else { return }
        diag.log("geofence", "Monitoring failed: \(error.localizedDescription)")
        rollingCenter = nil
    }

    // MARK: Diagnostics

    private func noteDelivery(_ locations: [CLLocation]) {
        diag.heartbeat()
        let now = Date()
        let background = UIApplication.shared.applicationState == .background
        if let last = lastDelivery, now.timeIntervalSince(last) > 5 * 60 {
            diag.log("gap", "No location updates for \(Diagnostics.duration(now.timeIntervalSince(last))) before this one.")
            backfillMotion(reason: "after a gap")
        } else if now.timeIntervalSince(lastBackfillAttempt) > 30 * 60 {
            backfillMotion(reason: "periodic")
        }
        lastDelivery = now
        stats.batches += 1
        if background { stats.backgroundBatches += 1 }
        for loc in locations where loc.horizontalAccuracy >= 0 {
            stats.bestAccuracy = min(stats.bestAccuracy, loc.horizontalAccuracy)
            stats.worstAccuracy = max(stats.worstAccuracy, loc.horizontalAccuracy)
        }
        if now.timeIntervalSince(stats.since) >= 10 * 60 { flushStats() }
    }

    /// One summary line per ~10 minutes of deliveries (and when the app changes state).
    func flushStats() {
        guard stats.batches > 0 || stats.droppedPaused > 0 else { stats = DeliveryStats(); return }
        let acc = stats.bestAccuracy.isFinite ? "accuracy \(Int(stats.bestAccuracy))–\(Int(stats.worstAccuracy)) m" : "no accuracy"
        var dropped: [String] = []
        if stats.droppedAccuracy > 0 { dropped.append("\(stats.droppedAccuracy) too inaccurate (>200 m)") }
        if stats.droppedStale > 0 { dropped.append("\(stats.droppedStale) stale/duplicate") }
        if stats.droppedPaused > 0 { dropped.append("\(stats.droppedPaused) while paused") }
        diag.log("location", "Last \(Diagnostics.duration(Date().timeIntervalSince(stats.since))): "
                 + "\(stats.batches) deliveries (\(stats.backgroundBatches) in background), \(stats.recorded) recorded, "
                 + "\(acc)" + (dropped.isEmpty ? "." : "; dropped " + dropped.joined(separator: ", ") + "."))
        stats = DeliveryStats()
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    // MARK: Interval mode ("Record a point every N minutes")

    // MARK: Pause

    /// Stops recording until `date`, then resumes by itself.
    func pause(until date: Date) {
        diag.log("recorder", "Paused until \(date.formatted(date: .abbreviated, time: .shortened)).")
        pausedUntil = date
        defaults.set(date, forKey: Keys.pausedUntil)
        isLowPower = false
        configureSchedule()
        WidgetSync.publish(widgetStatus, force: true)
    }

    func resume() {
        diag.log("recorder", "Resumed.")
        pausedUntil = nil
        defaults.removeObject(forKey: Keys.pausedUntil)
        configureSchedule()
        WidgetSync.publish(widgetStatus, force: true)
    }

    /// "Until tomorrow morning": 7:00 tomorrow.
    static func tomorrowMorning(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func configureSchedule() {
        stopSchedule()
        guard isRecording, interval > 0 || isPaused else {
            applyAccuracy()
            return
        }
        isLowPower = false
        nextPointAt = isPaused ? nil : Date()      // take the first point right away
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
        diag.heartbeat()
        let now = Date()
        if let until = pausedUntil {
            if now >= until { resume() }           // also restarts timed mode if it's on
            return
        }
        if let started = pointStartedAt {
            if now.timeIntervalSince(started) >= pointTimeout { finishPoint() }
        } else if let due = nextPointAt, now >= due {
            if now.timeIntervalSince(due) > 60 {
                diag.log("timed", "Point was due \(Diagnostics.duration(now.timeIntervalSince(due))) ago (app wasn't running).")
            }
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
        let started = pointStartedAt ?? Date()
        let waited = Int(Date().timeIntervalSince(started))
        if let best = bestCandidate {
            diag.log("timed", "Point: best fix ±\(Int(best.horizontalAccuracy)) m after \(waited) s"
                     + (best.horizontalAccuracy > 200 ? " (too inaccurate, not saved)." : "."))
            record(best)    // record() still drops fixes worse than 200 m
        } else {
            diag.log("timed", "Point: no fix at all within \(waited) s.")
        }
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
        let code = (error as? CLError)?.code
        if code == .locationUnknown { return }
        diag.log("error", "Location error: \(code.map { "CLError \($0.rawValue)" } ?? "") \(error.localizedDescription)")
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        diag.log("gps", "iOS PAUSED location updates (should not happen: auto-pause is off).")
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        diag.log("gps", "iOS resumed location updates.")
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        diag.heartbeat()
        let arrived = visit.arrivalDate == .distantPast ? "?" : visit.arrivalDate.formatted(date: .omitted, time: .shortened)
        let left = visit.departureDate == .distantFuture ? "still there" : "left \(visit.departureDate.formatted(date: .omitted, time: .shortened))"
        diag.log("visit", "iOS reported a visit: arrived \(arrived), \(left), ±\(Int(visit.horizontalAccuracy)) m.")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let previous = authorization
        authorization = manager.authorizationStatus
        diag.log("permission", "Location permission \(Self.describe(authorization)), precise "
                 + "\(manager.accuracyAuthorization == .fullAccuracy ? "on" : "OFF").")
        if isRecording && previous == .notDetermined && authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()   // step two of the request in start()
        }
        preciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        if isRecording && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) {
            beginUpdates()
        }
    }

    private func record(_ loc: CLLocation) {
        guard !isPaused else { stats.droppedPaused += 1; return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 200 else { stats.droppedAccuracy += 1; return }
        if let last = lastPoint, loc.timestamp <= last.t { stats.droppedStale += 1; return }
        stats.recorded += 1

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
        updateRollingRegion(around: loc)

        if PointStore.dayKey(point.t) == countDayKey {
            todayCount += 1
            WidgetSync.publish(widgetStatus, force: false)
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

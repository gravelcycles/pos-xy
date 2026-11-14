import Foundation

enum ActivityType: String, Codable, CaseIterable, Hashable {
    case stationary, walking, running, cycling, driving, flying, unknown
    // Set by hand (corrections) or by imports; the automatic classifier calls these "driving".
    // Appended after `unknown` so tie-breaks between the automatic types stay as they were.
    case train, bus, boat

    /// Types you can pick when correcting an activity, in menu order.
    static let correctable: [ActivityType] = [.walking, .running, .cycling, .driving, .train, .bus, .boat, .flying, .stationary]

    /// Unknown strings decode as `.unknown` instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityType(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .stationary: return "Stay"
        case .walking: return "Walk"
        case .running: return "Run"
        case .cycling: return "Bike"
        case .driving: return "Drive"
        case .flying: return "Flight"
        case .unknown: return "Unknown"
        case .train: return "Train"
        case .bus: return "Bus"
        case .boat: return "Boat"
        }
    }

    var symbol: String {
        switch self {
        case .stationary: return "mappin.circle.fill"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .flying: return "airplane"
        case .unknown: return "questionmark"
        case .train: return "tram.fill"
        case .bus: return "bus.fill"
        case .boat: return "ferry.fill"
        }
    }

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .stationary: return (0.55, 0.36, 0.85)
        case .walking: return (0.18, 0.70, 0.35)
        case .running: return (0.95, 0.55, 0.10)
        case .cycling: return (0.05, 0.65, 0.75)
        case .driving: return (0.20, 0.45, 0.95)
        case .flying: return (0.90, 0.25, 0.45)
        case .unknown: return (0.55, 0.55, 0.58)
        case .train: return (0.72, 0.47, 0.20)
        case .bus: return (0.85, 0.30, 0.20)
        case .boat: return (0.12, 0.38, 0.62)
        }
    }

    /// Draw as a dashed line (we didn't really see the path).
    var isDashed: Bool { self == .flying || self == .unknown }
}

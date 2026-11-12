import Foundation

enum Fmt {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road,
                                    numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1 min" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

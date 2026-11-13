import SwiftUI

/// "Record a point": continuously, a preset interval, or a custom one.
struct FrequencySection: View {
    @EnvironmentObject private var recorder: LocationRecorder

    private enum Unit: Int, CaseIterable, Identifiable {
        case seconds = 1, minutes = 60, hours = 3600
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .seconds: return "seconds"
            case .minutes: return "minutes"
            case .hours: return "hours"
            }
        }
    }

    private static let customTag = -1
    @State private var choice = 0
    @State private var customAmount = 10
    @State private var customUnit: Unit = .minutes
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Record a point", selection: $choice) {
                ForEach(LocationRecorder.intervalPresets, id: \.self) { seconds in
                    Text(LocationRecorder.describe(interval: seconds)).tag(seconds)
                }
                Text("Custom…").tag(Self.customTag)
            }

            if choice == Self.customTag {
                HStack {
                    Text("Every")
                    TextField("Amount", value: $customAmount, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                        .textFieldStyle(.roundedBorder)
                    Picker("Unit", selection: $customUnit) {
                        ForEach(Unit.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                if customSeconds != recorder.interval {
                    Text("Allowed: 10 seconds to 12 hours. Using \(LocationRecorder.describe(interval: recorder.interval).lowercased()).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if recorder.interval == 0 {
                Picker("GPS mode", selection: $recorder.powerMode) {
                    ForEach(LocationRecorder.PowerMode.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Frequency")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: load)
        .onChange(of: choice) { _, _ in apply() }
        .onChange(of: customAmount) { _, _ in apply() }
        .onChange(of: customUnit) { _, _ in apply() }
    }

    private var customSeconds: Int { max(customAmount, 0) * customUnit.rawValue }

    private var footer: String {
        if recorder.interval == 0 {
            return "Continuously records a point about every 15 m you move: the most detail and the best walk/bike/drive detection. Smart rests the GPS while you're standing still; Always precise is best on flights."
        }
        return "Takes one GPS point on that schedule and keeps the GPS off in between, which saves a lot of battery. Trips are still classified, but with less detail the longer the interval."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let seconds = recorder.interval
        if LocationRecorder.intervalPresets.contains(seconds) {
            choice = seconds
        } else {
            choice = Self.customTag
            if seconds % 3600 == 0 { customUnit = .hours; customAmount = seconds / 3600 }
            else if seconds % 60 == 0 { customUnit = .minutes; customAmount = seconds / 60 }
            else { customUnit = .seconds; customAmount = seconds }
        }
    }

    private func apply() {
        guard loaded else { return }
        if choice == Self.customTag {
            let range = LocationRecorder.customIntervalRange
            recorder.interval = min(max(customSeconds, range.lowerBound), range.upperBound)
        } else {
            recorder.interval = choice
        }
    }
}

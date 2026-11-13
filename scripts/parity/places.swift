// Prints detected places for a fixture (compare with web/tests/places_dump.mjs). Run with TZ set.
import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
struct F: Codable { var points: [TrackPoint] }
let pts = Segmenter.clean(try! TrackJSON.decoder().decode(F.self, from: data).points)
let cal = Calendar.current
let groups = Dictionary(grouping: pts) { cal.startOfDay(for: $0.t) }
for p in Places.detect(days: groups.keys.sorted().map { groups[$0]! }) {
    print("\(p.name ?? "-") \(String(format: "%.5f %.5f", p.lat, p.lon)) visits=\(p.visits) h=\(String(format: "%.2f", p.seconds / 3600)) night=\(String(format: "%.2f", p.night / 3600)) work=\(String(format: "%.2f", p.work / 3600)) days=\(p.days)")
}

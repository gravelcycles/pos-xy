// Prints segments for a fixture: "type first last metres" (compare with web/tests/parity.mjs).
import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
struct F: Codable { var points: [TrackPoint] }
let dec = TrackJSON.decoder()
let raw = (try? dec.decode(F.self, from: data).points) ?? (try! dec.decode([TrackPoint].self, from: data))
for s in Segmenter.segments(Segmenter.clean(raw)) {
    print("\(s.type.rawValue) \(s.first) \(s.last) \(Int(s.distance.rounded()))")
}

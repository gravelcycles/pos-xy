// Prints imported points for foreign files (compare with web/tests/import_dump.mjs).
import Foundation
func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
for path in CommandLine.arguments.dropFirst() {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    guard let r = Importers.importForeign(data) else { print("\(path): not foreign"); continue }
    let pts = r.points.sorted { $0.t < $1.t }
    print("== \(r.kind) \(pts.count)")
    for p in pts {
        print(String(format: "%.3f %.7f %.7f", p.t.timeIntervalSince1970, p.lat, p.lon), p.act?.rawValue ?? "-", p.spd.map(fmt) ?? "-", p.alt.map(fmt) ?? "-")
    }
}

import SwiftUI
import UIKit

/// Map tile settings. The map is the only thing in the iPhone app that uses the network, and it
/// only ever sends tile numbers (see `TileFetcher` for how they're blurred).
final class MapSettings: ObservableObject {
    static let shared = MapSettings()

    enum Detail: Int, CaseIterable, Identifiable {
        case coarse = 0, balanced, street
        var id: Int { rawValue }

        /// Most detailed tiles requested. Closer than this, the app enlarges them itself.
        var maxZoom: Int {
            switch self {
            case .coarse: return 14
            case .balanced: return 16
            case .street: return 18
            }
        }
        var label: String {
            switch self {
            case .coarse: return "Coarse"
            case .balanced: return "Balanced"
            case .street: return "Street"
            }
        }
        /// Rough size of the smallest area OSM can narrow a view down to (a block is the
        /// tile two zoom levels above `maxZoom`), at mid latitudes.
        var area: String {
            switch self {
            case .coarse: return "≈8 km"
            case .balanced: return "≈2 km"
            case .street: return "≈500 m"
            }
        }
    }

    private enum Keys {
        static let tiles = "map.tiles"
        static let detail = "map.detail"
        static let cellular = "map.cellular"
    }

    @Published var tilesOn: Bool {
        didSet { UserDefaults.standard.set(tilesOn, forKey: Keys.tiles) }
    }
    @Published var detail: Detail {
        didSet {
            UserDefaults.standard.set(detail.rawValue, forKey: Keys.detail)
            fetcher.maxZoom = detail.maxZoom
        }
    }
    @Published var cellular: Bool {
        didSet {
            UserDefaults.standard.set(cellular, forKey: Keys.cellular)
            fetcher.allowsCellular = cellular
        }
    }

    let fetcher: TileFetcher

    private init() {
        let d = UserDefaults.standard
        let detail = (d.object(forKey: Keys.detail) as? Int).flatMap(Detail.init(rawValue:)) ?? .balanced
        let cellular = d.object(forKey: Keys.cellular) as? Bool ?? true
        tilesOn = d.object(forKey: Keys.tiles) as? Bool ?? true
        self.detail = detail
        self.cellular = cellular
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTiles", isDirectory: true)
        fetcher = TileFetcher(directory: dir, userAgent: "PosXY-iOS (personal map viewer)",
                              maxZoom: detail.maxZoom, diskLimit: 200 << 20)
        fetcher.allowsCellular = cellular
        fetcher.prune()
    }

    /// Forget every downloaded tile (they reveal which areas you looked at).
    func clearCache() {
        fetcher.clear()
        TileImages.shared.removeAll()
    }
}

/// Decoded tiles in memory, shared by every map on screen. Bumps `version` when tiles arrive.
final class TileImages: ObservableObject {
    static let shared = TileImages()

    @Published private(set) var version = 0
    private let cache = NSCache<NSString, UIImage>()
    private var pending: Set<TileKey> = []
    private var bumpScheduled = false

    private init() {
        cache.countLimit = 150      // ~40 MB decoded at most
        // Background apps with a big memory footprint are the first iOS kills when the foreground
        // app needs memory, and a killed Pos XY records nothing until iOS relaunches it. So drop
        // every decoded tile when leaving the screen (they're on disk; reloading is instant).
        let nc = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.cache.removeAllObjects()
            }
        }
    }

    func image(_ k: TileKey) -> UIImage? {
        cache.object(forKey: k.description as NSString)
    }

    /// Asks for a tile (disk first, then its block from OSM). Main thread only.
    func request(_ k: TileKey) {
        guard Thread.isMainThread, MapSettings.shared.tilesOn, image(k) == nil, !pending.contains(k) else { return }
        pending.insert(k)
        MapSettings.shared.fetcher.load(k) { [weak self] data in
            let img = data.flatMap { UIImage(data: $0) }?.preparingForDisplay()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(k)
                guard let img else { return }
                self.cache.setObject(img, forKey: k.description as NSString)
                self.scheduleBump()
            }
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        scheduleBump()
    }

    private func scheduleBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.bumpScheduled = false
            self.version &+= 1
        }
    }
}

/// Settings → Map.
struct MapSettingsSection: View {
    @ObservedObject private var settings = MapSettings.shared
    @State private var cacheBytes = 0

    var body: some View {
        Section {
            Toggle(isOn: $settings.tilesOn) {
                Label("OpenStreetMap background", systemImage: "map")
            }
            if settings.tilesOn {
                Picker(selection: $settings.detail) {
                    ForEach(MapSettings.Detail.allCases) { d in
                        Text("\(d.label) (\(d.area))").tag(d)
                    }
                } label: {
                    Label("Map detail", systemImage: "square.grid.3x3")
                }
                Toggle(isOn: $settings.cellular) {
                    Label("Use cellular data", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            HStack {
                Text("Downloaded map")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    settings.clearCache()
                    cacheBytes = 0
                }
                .buttonStyle(.borderless)
                .disabled(cacheBytes == 0)
            }
        } header: {
            Text("Map")
        } footer: {
            Text(settings.tilesOn
                 ? "Maps download from OpenStreetMap in whole blocks, so OSM only learns which \(settings.detail.area) square you looked at, never your track. Closer than that, the map is enlarged on the phone. Each area is downloaded once and kept here. Your IP address still reveals your rough area, as with any website. Off: maps are drawn without a background and nothing is downloaded."
                 : "Maps are drawn without a background. Nothing is downloaded.")
        }
        .task(id: settings.tilesOn) {
            cacheBytes = await Task.detached(priority: .utility) { MapSettings.shared.fetcher.diskUsage() }.value
        }
    }
}

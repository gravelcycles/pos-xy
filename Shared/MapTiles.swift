import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Tile math (Web Mercator, OSM "slippy map" numbering)

struct TileKey: Hashable, CustomStringConvertible {
    var z: Int, x: Int, y: Int
    var description: String { "\(z)/\(x)/\(y)" }

    /// The block of tiles this tile is downloaded with: every tile at zoom `z` that falls inside
    /// the ancestor tile `levels` zooms up (4×4 = 16 tiles for `levels` = 2).
    func block(levels: Int) -> [TileKey] {
        let d = min(levels, z)
        let n = 1 << d
        let bx = (x >> d) << d, by = (y >> d) << d
        var out: [TileKey] = []
        out.reserveCapacity(n * n)
        for dy in 0..<n { for dx in 0..<n { out.append(TileKey(z: z, x: bx + dx, y: by + dy)) } }
        return out
    }

    /// The ancestor tile whose area identifies a block (what the tile server can learn).
    func blockID(levels: Int) -> TileKey {
        let d = min(levels, z)
        return TileKey(z: z - d, x: x >> d, y: y >> d)
    }

    var isValid: Bool { z >= 0 && z <= 22 && x >= 0 && y >= 0 && x < (1 << z) && y < (1 << z) }
}

/// Web Mercator in "world units": the whole world is the unit square, x east, y south.
enum WebMercator {
    static let maxLat = 85.051_128_78

    static func world(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let la = max(-maxLat, min(maxLat, lat)) * .pi / 180
        let x = (lon + 180) / 360
        let y = (1 - log(tan(la) + 1 / cos(la)) / .pi) / 2
        return (x, y)
    }

    static func coordinate(x: Double, y: Double) -> (lat: Double, lon: Double) {
        let lon = x * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return (lat, lon)
    }

    /// Zoom (continuous) at which a world-unit box `w`×`h` fills `width`×`height` points.
    static func fitZoom(w: Double, h: Double, width: Double, height: Double, tileSize: Double = 256) -> Double {
        let zx = w > 0 ? log2(width / (w * tileSize)) : .infinity
        let zy = h > 0 ? log2(height / (h * tileSize)) : .infinity
        return min(zx, zy)
    }
}

// MARK: - Privacy-preserving tile downloader

/// Downloads OpenStreetMap tiles in a way that tells the tile server as little as possible:
///
/// * **Blocks, not tiles.** Asking for one tile downloads every tile of its 4×4 block (the area of
///   the tile two zoom levels up), in random order. The server learns which block you looked at,
///   not which part of it, so it can't centre on where you were.
/// * **Zoom cap.** The caller limits the zoom (iPhone: Map detail setting). Closer than that, the
///   app enlarges the most detailed tiles itself instead of asking for finer ones.
/// * **Downloaded once.** Tiles are kept on disk (Data Protection, not backed up) and never
///   re-requested while cached, so repeatedly viewing home or work sends nothing.
/// * **Nothing identifying.** No cookies, no cache validators, no Referer, a generic
///   User-Agent without a version or contact, a fixed Accept-Language.
///
/// Only the tile numbers are ever sent; track points never leave the device.
final class TileFetcher {
    static let osmTemplate = "https://tile.openstreetmap.org/%d/%d/%d.png"

    /// printf-style template taking z, x, y.
    let urlTemplate: String

    /// Zoom levels between a tile and its block (2 → 16-tile blocks).
    let blockLevels: Int
    /// Hard limit on requested zoom (defence in depth; callers cap too).
    var maxZoom: Int
    var allowsCellular = true
    let directory: URL
    let diskLimit: Int

    private let session: URLSession
    private let queue = DispatchQueue(label: "posxy.tiles")
    private var waiters: [TileKey: [(Data?) -> Void]] = [:]
    private var activeBlocks: Set<TileKey> = []
    private var failedBlocks: [TileKey: Date] = [:]
    #if os(iOS)
    private let protection: FileProtectionType? = .completeUntilFirstUserAuthentication
    #else
    private let protection: FileProtectionType? = nil
    #endif

    /// Posted on the main queue after tiles arrive (object: the fetcher).
    static let didLoad = Notification.Name("posxy.tilesDidLoad")

    init(directory: URL, userAgent: String, maxZoom: Int = 19, blockLevels: Int = 2, diskLimit: Int = 200 << 20,
         urlTemplate: String = TileFetcher.osmTemplate) {
        self.directory = directory
        self.urlTemplate = urlTemplate
        self.maxZoom = maxZoom
        self.blockLevels = blockLevels
        self.diskLimit = diskLimit
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en", "Accept": "image/png"]
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: protection.map { [.protectionKey: $0] })
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func file(_ k: TileKey) -> URL {
        directory.appendingPathComponent("\(k.z)-\(k.x)-\(k.y).png")
    }

    /// The tile if it's on disk (never touches the network).
    func cached(_ k: TileKey) -> Data? {
        try? Data(contentsOf: file(k))
    }

    /// Delivers the tile (from disk, or by downloading its whole block) on a background queue.
    /// `nil` means unavailable for now (offline, refused, above the zoom cap).
    func load(_ k: TileKey, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            if let data = cached(k) { completion(data); return }
            guard k.isValid, k.z <= maxZoom else { completion(nil); return }
            let id = k.blockID(levels: blockLevels)
            if let failed = failedBlocks[id], Date().timeIntervalSince(failed) < 30 { completion(nil); return }
            waiters[k, default: []].append(completion)
            guard !activeBlocks.contains(id) else { return }
            activeBlocks.insert(id)
            fetchBlock(id: id, tiles: k.block(levels: blockLevels).filter { cached($0) == nil }.shuffled())
        }
    }

    private func fetchBlock(id: TileKey, tiles: [TileKey]) {
        guard !tiles.isEmpty else { activeBlocks.remove(id); return }
        let progress = BlockProgress(remaining: tiles.count)
        for k in tiles {
            guard let url = URL(string: String(format: urlTemplate, k.z, k.x, k.y)) else { continue }
            var req = URLRequest(url: url)
            req.allowsCellularAccess = allowsCellular
            session.dataTask(with: req) { [weak self] data, response, _ in
                guard let self else { return }
                let ok = (response as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
                self.queue.async {
                    if ok, let data {
                        let url = self.file(k)
                        if !FileManager.default.createFile(atPath: url.path, contents: data,
                                                           attributes: self.protection.map { [.protectionKey: $0] }) {
                            try? data.write(to: url)
                        }
                    } else {
                        progress.anyFailed = true
                    }
                    for w in self.waiters.removeValue(forKey: k) ?? [] { w(ok ? data : nil) }
                    progress.remaining -= 1
                    if progress.remaining == 0 {
                        self.activeBlocks.remove(id)
                        if progress.anyFailed { self.failedBlocks[id] = Date() } else { self.failedBlocks[id] = nil }
                        // Waiters for tiles that were already cached when the block started.
                        for key in self.waiters.keys where key.blockID(levels: self.blockLevels) == id {
                            let data = self.cached(key)
                            for w in self.waiters.removeValue(forKey: key) ?? [] { w(data) }
                        }
                        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didLoad, object: self) }
                    }
                }
            }.resume()
        }
    }

    /// Per-block bookkeeping, only touched on `queue`.
    private final class BlockProgress {
        var remaining: Int
        var anyFailed = false
        init(remaining: Int) { self.remaining = remaining }
    }

    // MARK: Disk

    func diskUsage() -> Int {
        queue.sync { files().reduce(0) { $0 + $1.size } }
    }

    func clear() {
        queue.sync {
            for f in files() { try? FileManager.default.removeItem(at: f.url) }
            failedBlocks.removeAll()
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didLoad, object: self) }
    }

    /// Deletes the oldest tiles once the cache is over its limit.
    func prune() {
        queue.async { [self] in
            var all = files()
            var total = all.reduce(0) { $0 + $1.size }
            guard total > diskLimit else { return }
            all.sort { $0.date < $1.date }
            for f in all where total > diskLimit * 3 / 4 {
                try? FileManager.default.removeItem(at: f.url)
                total -= f.size
            }
        }
    }

    private func files() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "png" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
    }
}

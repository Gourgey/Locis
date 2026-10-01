import Foundation

/// Where parking data comes from: the bundled synthetic dataset, or the published
/// static dataset on the web.
public enum DataSourceConfiguration: Sendable, Equatable {
    case demo(directory: URL)
    case remote(baseURL: URL)

    public var isDemo: Bool {
        if case .demo = self { true } else { false }
    }
}

public enum ParkingDataError: Error, Equatable, Sendable {
    /// No network and nothing usable cached.
    case offline
    /// The data service did not respond usefully.
    case unavailable
    /// The dataset needs a newer version of the app.
    case requiresAppUpdate
}

/// A manifest and how fresh it is.
public struct ManifestState: Sendable, Equatable {
    public let manifest: Manifest
    /// When this copy was fetched from the source.
    public let fetchedAt: Date
    /// True when served from the device cache because the source was unreachable.
    public let isFromCache: Bool

    public init(manifest: Manifest, fetchedAt: Date, isFromCache: Bool) {
        self.manifest = manifest
        self.fetchedAt = fetchedAt
        self.isFromCache = isFromCache
    }

    /// Whether this app version may interpret the dataset.
    public var isCompatible: Bool {
        manifest.formatVersion == SupportedFormat.tileFormatVersion
            && manifest.minEngineVersion <= ParkingRulesEngine.engineVersion
    }
}

public enum SupportedFormat {
    public static let tileFormatVersion = 1
}

/// The outcome of loading the tiles for a map area.
public struct LoadedArea: Sendable {
    public var features: [String: Feature] = [:]
    /// Tiles the manifest lists that could not be loaded.
    public var failedTiles: Set<TileCoordinate> = []
    /// Tiles containing features this app version could not read.
    public var incompleteTiles: Set<TileCoordinate> = []
    /// Requested tiles for which the dataset has no data at all.
    public var emptyTiles: Set<TileCoordinate> = []
    public var tileOfFeature: [String: Set<TileCoordinate>] = [:]

    public init() {}
}

public protocol ParkingDataProviding: Sendable {
    /// The dataset index. Falls back to a cached copy when the source is unreachable.
    func manifest(refresh: Bool) async throws -> ManifestState
    /// Features for the given tiles (cached tiles are not downloaded again).
    func load(_ tiles: [TileCoordinate], using manifest: Manifest) async -> LoadedArea
}

/// Minimal HTTP abstraction so the remote provider can be tested without a network.
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        // No cookies, no credentials, nothing identifying.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: Bundled demo data

public struct DemoDataProvider: ParkingDataProviding {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func manifest(refresh: Bool) async throws -> ManifestState {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            let manifest = try? LocisDecoding.decoder().decode(Manifest.self, from: data)
        else { throw ParkingDataError.unavailable }
        return ManifestState(manifest: manifest, fetchedAt: manifest.generatedAt, isFromCache: false)
    }

    public func load(_ tiles: [TileCoordinate], using manifest: Manifest) async -> LoadedArea {
        var area = LoadedArea()
        for tile in tiles {
            guard let hash = manifest.tiles[tile.key] else {
                area.emptyTiles.insert(tile)
                continue
            }
            let url = directory.appendingPathComponent("tiles/\(tile.z)/\(tile.x)/\(tile.y)-\(hash).json")
            guard let data = try? Data(contentsOf: url),
                let decoded = try? LocisDecoding.decoder().decode(Tile.self, from: data)
            else {
                area.failedTiles.insert(tile)
                continue
            }
            area.add(decoded, at: tile)
        }
        return area
    }
}

extension LoadedArea {
    mutating func add(_ tile: Tile, at coordinate: TileCoordinate) {
        if tile.undecodable > 0 { incompleteTiles.insert(coordinate) }
        for feature in tile.features {
            features[feature.id] = feature
            tileOfFeature[feature.id, default: []].insert(coordinate)
        }
    }

    public mutating func merge(_ other: LoadedArea) {
        features.merge(other.features) { _, new in new }
        failedTiles.formUnion(other.failedTiles)
        incompleteTiles.formUnion(other.incompleteTiles)
        emptyTiles.formUnion(other.emptyTiles)
        for (id, tiles) in other.tileOfFeature { tileOfFeature[id, default: []].formUnion(tiles) }
    }

    /// True when a rule for this feature's area may be missing.
    public func isIncomplete(around featureID: String) -> Bool {
        guard let tiles = tileOfFeature[featureID] else { return true }
        return !tiles.isDisjoint(with: incompleteTiles) || !tiles.isDisjoint(with: failedTiles)
    }
}

// MARK: Published static dataset

/// Reads the dataset published by the pipeline, caching the manifest and tiles on
/// the device. Tile files are named by content hash, so a cached tile is valid for
/// as long as the manifest still lists that hash, and is never downloaded twice.
public actor RemoteDataProvider: ParkingDataProviding {
    let baseURL: URL
    let cacheDirectory: URL
    let http: HTTPFetching
    let now: @Sendable () -> Date
    private var memory: [String: Tile] = [:]
    private var current: ManifestState?

    /// A manifest newer than this is reused without asking the network again.
    static let manifestMaxAge: TimeInterval = 15 * 60

    public init(
        baseURL: URL, cacheDirectory: URL, http: HTTPFetching = URLSessionFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.cacheDirectory = cacheDirectory
        self.http = http
        self.now = now
    }

    public func manifest(refresh: Bool) async throws -> ManifestState {
        if !refresh, let current, !current.isFromCache, now().timeIntervalSince(current.fetchedAt) < Self.manifestMaxAge {
            return current
        }
        let cacheFile = cacheDirectory.appendingPathComponent("manifest.json")
        do {
            let (data, status) = try await http.data(from: baseURL.appendingPathComponent("manifest.json"))
            guard status == 200 else { throw ParkingDataError.unavailable }
            let manifest = try LocisDecoding.decoder().decode(Manifest.self, from: data)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            let state = ManifestState(manifest: manifest, fetchedAt: now(), isFromCache: false)
            current = state
            return state
        } catch {
            // Fall back to the last manifest we saw, clearly marked as cached.
            if let data = try? Data(contentsOf: cacheFile),
                let manifest = try? LocisDecoding.decoder().decode(Manifest.self, from: data)
            {
                let fetched =
                    (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date)
                    ?? manifest.generatedAt
                let state = ManifestState(manifest: manifest, fetchedAt: fetched, isFromCache: true)
                current = state
                return state
            }
            if error is URLError { throw ParkingDataError.offline }
            throw ParkingDataError.unavailable
        }
    }

    public func load(_ tiles: [TileCoordinate], using manifest: Manifest) async -> LoadedArea {
        var area = LoadedArea()
        await withTaskGroup(of: (TileCoordinate, Tile?, Bool).self) { group in
            for tile in tiles {
                guard let hash = manifest.tiles[tile.key] else {
                    area.emptyTiles.insert(tile)
                    continue
                }
                group.addTask { await (tile, self.tile(tile, hash: hash), true) }
            }
            for await (coordinate, tile, _) in group {
                if let tile {
                    area.add(tile, at: coordinate)
                } else {
                    area.failedTiles.insert(coordinate)
                }
            }
        }
        return area
    }

    private func tile(_ coordinate: TileCoordinate, hash: String) async -> Tile? {
        let name = "\(coordinate.z)/\(coordinate.x)/\(coordinate.y)-\(hash).json"
        if let cached = memory[name] { return cached }
        let file = cacheDirectory.appendingPathComponent("tiles/\(name)")
        let decoder = LocisDecoding.decoder()
        if let data = try? Data(contentsOf: file), let tile = try? decoder.decode(Tile.self, from: data) {
            remember(tile, as: name)
            return tile
        }
        if Task.isCancelled { return nil }
        guard let (data, status) = try? await http.data(from: baseURL.appendingPathComponent("tiles/\(name)")),
            status == 200, let tile = try? decoder.decode(Tile.self, from: data)
        else { return nil }
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Drop superseded versions of this tile.
        let prefix = "\(coordinate.y)-"
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        try? data.write(to: file, options: .atomic)
        remember(tile, as: name)
        return tile
    }

    private func remember(_ tile: Tile, as name: String) {
        if memory.count > 200 { memory.removeAll() }
        memory[name] = tile
    }
}

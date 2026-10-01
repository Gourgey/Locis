import Foundation
import Testing

@testable import LocisKit

/// Serves the bundled demo dataset as if it were a web server, counting requests.
final class FakeServer: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _online = true
    var root: URL

    init(root: URL) { self.root = root }

    var requests: [String] { lock.withLock { _requests } }
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }

    func data(from url: URL) async throws -> (Data, Int) {
        let path = url.path.replacingOccurrences(of: "/data/", with: "")
        lock.withLock { _requests.append(path) }
        guard online else { throw URLError(.notConnectedToInternet) }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return (Data(), 404) }
        return (data, 200)
    }
}

@Suite("Loading data")
struct DataProviderTests {
    let demoRoot = DemoData.directory

    func makeProvider(_ server: FakeServer) -> (RemoteDataProvider, URL) {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("locis-tests-\(UUID().uuidString)")
        let provider = RemoteDataProvider(baseURL: URL(string: "https://example.invalid/data/")!, cacheDirectory: cache, http: server)
        return (provider, cache)
    }

    func demoTiles(_ manifest: Manifest) -> [TileCoordinate] {
        manifest.tiles.keys.map { key in
            let parts = key.split(separator: "/").map { Int($0)! }
            return TileCoordinate(x: parts[0], y: parts[1], z: manifest.tileZoom)
        }
    }

    @Test func tileMathsMatchesThePipeline() {
        // The demo quarter is in tiles 16358/10906 and 16359/10906 at zoom 15.
        let tile = TileCoordinate.containing(longitude: -0.2792, latitude: 51.4372, zoom: 15)
        #expect(tile == TileCoordinate(x: 16358, y: 10906, z: 15))
        let box = BoundingBox(west: -0.2800, south: 51.4365, east: -0.2724, north: 51.4399)
        #expect(Set(TileCoordinate.covering(box, zoom: 15).map(\.key)) == ["16358/10906", "16359/10906"])
        #expect(box.expanded(by: 0.5).contains(box))
    }

    @Test func demoProviderLoadsBundledData() async throws {
        let provider = DemoDataProvider(directory: demoRoot)
        let state = try await provider.manifest(refresh: false)
        #expect(state.isCompatible && state.manifest.synthetic)
        let nowhere = TileCoordinate(x: 1, y: 1, z: 15)
        let area = await provider.load(demoTiles(state.manifest) + [nowhere], using: state.manifest)
        #expect(area.features.count == state.manifest.counts.features)
        #expect(area.emptyTiles == [nowhere])
        #expect(area.failedTiles.isEmpty && area.incompleteTiles.isEmpty)
    }

    @Test func remoteTilesAreDownloadedOnceThenServedFromCache() async throws {
        let server = FakeServer(root: demoRoot)
        let (provider, cache) = makeProvider(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        let state = try await provider.manifest(refresh: false)
        let tiles = demoTiles(state.manifest)
        let first = await provider.load(tiles, using: state.manifest)
        #expect(first.features.count == state.manifest.counts.features)
        #expect(server.requests.filter { $0.hasPrefix("tiles/") }.count == tiles.count)
        _ = await provider.load(tiles, using: state.manifest)
        #expect(server.requests.filter { $0.hasPrefix("tiles/") }.count == tiles.count)

        // A new provider (a later app launch) reads the tiles from disk.
        let later = RemoteDataProvider(baseURL: URL(string: "https://example.invalid/data/")!, cacheDirectory: cache, http: server)
        _ = await later.load(tiles, using: state.manifest)
        #expect(server.requests.filter { $0.hasPrefix("tiles/") }.count == tiles.count)
    }

    @Test func manifestIsReusedWhileFresh() async throws {
        let server = FakeServer(root: demoRoot)
        let (provider, cache) = makeProvider(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = try await provider.manifest(refresh: false)
        _ = try await provider.manifest(refresh: false)
        #expect(server.requests.filter { $0 == "manifest.json" }.count == 1)
        _ = try await provider.manifest(refresh: true)
        #expect(server.requests.filter { $0 == "manifest.json" }.count == 2)
    }

    @Test func offlineFallsBackToCachedDataAndSaysSo() async throws {
        let server = FakeServer(root: demoRoot)
        let (provider, cache) = makeProvider(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        let online = try await provider.manifest(refresh: false)
        let tiles = demoTiles(online.manifest)
        _ = await provider.load([tiles[0]], using: online.manifest)

        server.online = false
        let offline = try await provider.manifest(refresh: true)
        #expect(offline.isFromCache)
        #expect(offline.manifest == online.manifest)
        let area = await provider.load(tiles, using: offline.manifest)
        #expect(area.failedTiles == Set(tiles.dropFirst()))
        #expect(!area.features.isEmpty)
        // Features whose tile failed to load are flagged so they are never shown as available.
        let missing = area.features.keys.filter { area.isIncomplete(around: $0) }
        #expect(missing.isEmpty)  // loaded features all came from the cached tile
    }

    @Test func offlineWithNothingCachedIsAnError() async {
        let server = FakeServer(root: demoRoot)
        server.online = false
        let (provider, cache) = makeProvider(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        await #expect(throws: ParkingDataError.offline) { try await provider.manifest(refresh: false) }
    }

    @Test func missingManifestIsUnavailable() async {
        let server = FakeServer(root: FileManager.default.temporaryDirectory.appendingPathComponent("nothing-here"))
        let (provider, cache) = makeProvider(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        await #expect(throws: ParkingDataError.unavailable) { try await provider.manifest(refresh: false) }
    }

    @Test func datasetNeedingANewerEngineIsIncompatible() throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: demoRoot.appendingPathComponent("manifest.json"))) as! JSON
        json["minEngineVersion"] = ParkingRulesEngine.engineVersion + 1
        let manifest = try LocisDecoding.decoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!ManifestState(manifest: manifest, fetchedAt: Date(), isFromCache: false).isCompatible)
        json["minEngineVersion"] = 1
        json["formatVersion"] = 2
        let newer = try LocisDecoding.decoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!ManifestState(manifest: newer, fetchedAt: Date(), isFromCache: false).isCompatible)
    }
}

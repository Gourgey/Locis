import Foundation

/// A map tile in the standard Web Mercator XYZ scheme.
public struct TileCoordinate: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int

    public init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Key used in the manifest's tile index.
    public var key: String { "\(x)/\(y)" }

    public static func containing(longitude: Double, latitude: Double, zoom: Int) -> TileCoordinate {
        let n = Double(1 << zoom)
        let lat = max(min(latitude, 85.05112878), -85.05112878) * .pi / 180
        let x = Int(floor((longitude + 180) / 360 * n))
        let y = Int(floor((1 - asinh(tan(lat)) / .pi) / 2 * n))
        let limit = (1 << zoom) - 1
        return TileCoordinate(x: min(max(x, 0), limit), y: min(max(y, 0), limit), z: zoom)
    }

    /// Every tile touched by a bounding box.
    public static func covering(_ box: BoundingBox, zoom: Int) -> [TileCoordinate] {
        let topLeft = containing(longitude: box.west, latitude: box.north, zoom: zoom)
        let bottomRight = containing(longitude: box.east, latitude: box.south, zoom: zoom)
        guard topLeft.x <= bottomRight.x, topLeft.y <= bottomRight.y else { return [] }
        var tiles: [TileCoordinate] = []
        for x in topLeft.x...bottomRight.x {
            for y in topLeft.y...bottomRight.y {
                tiles.append(TileCoordinate(x: x, y: y, z: zoom))
            }
        }
        return tiles
    }
}

/// A WGS84 bounding box.
public struct BoundingBox: Sendable, Equatable {
    public let west: Double
    public let south: Double
    public let east: Double
    public let north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    public var widthDegrees: Double { east - west }
    public var heightDegrees: Double { north - south }

    public func contains(_ other: BoundingBox) -> Bool {
        other.west >= west && other.east <= east && other.south >= south && other.north <= north
    }

    public func intersects(_ other: BoundingBox) -> Bool {
        !(other.east < west || other.west > east || other.north < south || other.south > north)
    }

    /// The box grown by a fraction of its size on every side.
    public func expanded(by fraction: Double) -> BoundingBox {
        let dx = widthDegrees * fraction
        let dy = heightDegrees * fraction
        return BoundingBox(west: west - dx, south: south - dy, east: east + dx, north: north + dy)
    }
}

import Foundation

/// How a provision takes part in deciding whether waiting is legal.
///
/// Decoding is tolerant: a role this app version does not know becomes
/// `.unsupported`, which the engine reports as unknown instead of ignoring.
public enum Role: String, Sendable, Codable, Equatable {
    case permission
    case prohibition
    case baySuspension
    case restrictionSuspension
    case zone
    case info
    case unsupported

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Role(rawValue: raw) ?? .unsupported
    }
}

/// What kind of kerb space or restriction a provision describes.
public enum Category: String, Sendable, Codable, Equatable {
    case standard, paid, permit, limitedWaiting
    case disabled, motorcycle, loading, taxi, cycle
    case noWaiting, noStopping, noLoading, redRoute, clearway, zigzag, busStop, crossing, footway
    case suspension
    case controlledParkingZone, restrictedParkingZone, permitParkingArea
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Category(rawValue: raw) ?? .other
    }

    /// Bays set aside for a particular kind of user, drawn distinctly on the map.
    public var isSpecialist: Bool {
        switch self {
        case .disabled, .motorcycle, .loading, .taxi, .cycle: true
        default: false
        }
    }
}

/// Where a provision is in its legal life. Absent means in force.
public enum Lifecycle: String, Sendable, Codable, Equatable {
    /// A revocation recorded for this kerb: what it revoked cannot be linked reliably.
    case revocation
    /// A notice of intention to make a temporary order: planned, not yet made.
    case intended
    case unrecognised

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Lifecycle(rawValue: raw) ?? .unrecognised
    }
}

/// How precisely the source geometry locates the rule.
public enum GeometryQuality: String, Sendable, Codable, Equatable {
    /// A line drawn on the kerb (or near/far side): the precise case.
    case kerb
    /// A line on the road centreline: the side of the road is not recorded.
    case centreline
    /// A line standing for a zone, not a kerb.
    case zoneLine
    /// A polygon: an area, never to be drawn as a kerb line.
    case area
    case point
    case unrecognised

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GeometryQuality(rawValue: raw) ?? .unrecognised
    }
}

public struct Coordinate: Sendable, Equatable, Hashable {
    public let longitude: Double
    public let latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

/// Feature geometry in WGS84.
public enum Geometry: Sendable, Equatable {
    /// One or more line parts.
    case line([[Coordinate]])
    /// One or more polygons, each a list of rings (outer ring first).
    case polygon([[[Coordinate]]])
    case point([Coordinate])

    /// A representative position, used for directions and map selection.
    public var representativeCoordinate: Coordinate? {
        switch self {
        case .line(let parts):
            guard let longest = parts.max(by: { $0.count < $1.count }), !longest.isEmpty else { return nil }
            return longest[longest.count / 2]
        case .polygon(let polygons):
            guard let ring = polygons.first?.first, !ring.isEmpty else { return nil }
            let lon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
            let lat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
            return Coordinate(longitude: lon, latitude: lat)
        case .point(let points):
            return points.first
        }
    }
}

extension Geometry: Decodable {
    private enum Keys: String, CodingKey { case type, coords }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        func coordinate(_ pair: [Double]) throws -> Coordinate {
            guard pair.count >= 2, (-180...180).contains(pair[0]), (-90...90).contains(pair[1]) else {
                throw DecodingError.dataCorruptedError(forKey: .coords, in: container, debugDescription: "bad position")
            }
            return Coordinate(longitude: pair[0], latitude: pair[1])
        }
        switch type {
        case "line":
            let raw = try container.decode([[[Double]]].self, forKey: .coords)
            self = .line(try raw.map { try $0.map(coordinate) })
        case "polygon":
            let raw = try container.decode([[[[Double]]]].self, forKey: .coords)
            self = .polygon(try raw.map { try $0.map { try $0.map(coordinate) } })
        case "point":
            let raw = try container.decode([[Double]].self, forKey: .coords)
            self = .point(try raw.map(coordinate))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown geometry type \(type)")
        }
    }
}

public struct ActivityEvent: Sendable, Decodable, Equatable {
    public enum Kind: String, Sendable, Decodable { case start, stop }
    public let at: Date
    public let type: Kind
}

public struct OffListRegulation: Sendable, Decodable, Equatable {
    public let name: String
    public let text: String
}

/// One regulated place of one D-TRO provision, as published in a tile.
public struct Feature: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    /// D-TRO record id.
    public let dtro: String
    /// Provision reference within the record.
    public let prov: String
    /// D-TRO regulationType, or "offList".
    public let reg: String
    public let role: Role
    public let cat: Category
    public let name: String
    public let desc: String
    public let tro: String
    public let auth: String?
    public let authCode: Int?
    /// D-TRO orderReportingPoint.
    public let orp: String?
    public let temporary: Bool
    public let cond: ConditionNode
    public let schema: String?
    public let lifecycle: Lifecycle?
    public let offList: OffListRegulation?
    /// Coming-into-force date, `yyyy-MM-dd` in London time.
    public let from: String?
    /// Date an experimental order ceased, `yyyy-MM-dd`.
    public let until: String?
    /// Provision references this (temporary) provision overrides while it applies.
    public let overrides: [String]?
    public let activity: [ActivityEvent]?
    public let updated: Date?
    public let published: Date?
    public let geom: Geometry
    public let geomQuality: GeometryQuality
    public let lateral: String?
    public let issues: [String]?
    /// Other features covering the same kerb, evaluated together with this one.
    public let related: [String]?
    /// The subset of `related` covering only part of this feature's length.
    public let partial: [String]?
    /// Contextual zones this feature lies in.
    public let zones: [String]?

    public init(
        id: String, dtro: String, prov: String, reg: String, role: Role, cat: Category, name: String,
        desc: String, tro: String, auth: String?, authCode: Int?, orp: String?, temporary: Bool,
        cond: ConditionNode, schema: String?, lifecycle: Lifecycle?, offList: OffListRegulation?,
        from: String?, until: String?, overrides: [String]?, activity: [ActivityEvent]?, updated: Date?,
        published: Date?, geom: Geometry, geomQuality: GeometryQuality, lateral: String?, issues: [String]?,
        related: [String]?, partial: [String]?, zones: [String]?
    ) {
        self.id = id
        self.dtro = dtro
        self.prov = prov
        self.reg = reg
        self.role = role
        self.cat = cat
        self.name = name
        self.desc = desc
        self.tro = tro
        self.auth = auth
        self.authCode = authCode
        self.orp = orp
        self.temporary = temporary
        self.cond = cond
        self.schema = schema
        self.lifecycle = lifecycle
        self.offList = offList
        self.from = from
        self.until = until
        self.overrides = overrides
        self.activity = activity
        self.updated = updated
        self.published = published
        self.geom = geom
        self.geomQuality = geomQuality
        self.lateral = lateral
        self.issues = issues
        self.related = related
        self.partial = partial
        self.zones = zones
    }

    public func hasIssue(_ code: String) -> Bool { issues?.contains(code) ?? false }

    /// Whether the feature is drawn as a kerb line the user can select.
    public var isKerbLine: Bool {
        guard case .line = geom else { return false }
        return geomQuality == .kerb || geomQuality == .centreline
    }

    public static func == (lhs: Feature, rhs: Feature) -> Bool {
        lhs.id == rhs.id && lhs.updated == rhs.updated && lhs.related == rhs.related
    }
}

public struct Tile: Sendable, Decodable {
    public let v: Int
    public let z: Int
    public let x: Int
    public let y: Int
    public let features: [Feature]
    /// Features from neighbouring tiles that this tile's features are evaluated
    /// against. They are not drawn from this tile.
    public let context: [Feature]
    /// Features in the tile that this app version could not read. When this is not
    /// zero a rule may be missing, so nothing in the tile can be shown as allowed.
    public let undecodable: Int

    private enum Keys: String, CodingKey { case v, z, x, y, features, context }
    private struct Lossy: Decodable {
        let value: Feature?
        init(from decoder: Decoder) throws { value = try? Feature(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        v = try container.decode(Int.self, forKey: .v)
        z = try container.decode(Int.self, forKey: .z)
        x = try container.decode(Int.self, forKey: .x)
        y = try container.decode(Int.self, forKey: .y)
        let lossy = try container.decode([Lossy].self, forKey: .features)
        features = lossy.compactMap(\.value)
        let lossyContext = try container.decodeIfPresent([Lossy].self, forKey: .context) ?? []
        context = lossyContext.compactMap(\.value)
        undecodable = (lossy.count - features.count) + (lossyContext.count - context.count)
    }
}

public enum LocisDecoding {
    /// Decoder for manifests and tiles (ISO 8601 UTC dates).
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

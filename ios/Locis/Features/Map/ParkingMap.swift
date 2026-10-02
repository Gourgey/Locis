import LocisKit
import MapKit
import SwiftUI

/// A one-off instruction to move the map.
struct MapCommand: Equatable {
    enum Kind: Equatable {
        case region(center: CLLocationCoordinate2D, metres: CLLocationDistance)
        case userLocation

        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.userLocation, .userLocation): true
            case (.region(let a, let m), .region(let b, let n)):
                a.latitude == b.latitude && a.longitude == b.longitude && m == n
            default: false
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var animated = true
}

/// The Apple Map with parking overlays, and tap-to-select on those overlays.
///
/// A busy street scene has well over a thousand kerb sections. Drawn as individual
/// SwiftUI map shapes they take seconds to appear, so this wraps `MKMapView` and
/// draws every line of one style as a single overlay (`MKMultiPolyline`).
struct ParkingMap: UIViewRepresentable {
    let items: [MapItem]
    let zones: [ZoneItem]
    /// Changes whenever `items` or `zones` do.
    let revision: Int
    let selectedID: String?
    let destination: ResolvedPlace?
    let showsUserLocation: Bool
    let command: MapCommand?
    let onRegionChange: (BoundingBox) -> Void
    let onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.register(PointItemView.self, forAnnotationViewWithReuseIdentifier: PointItemView.reuseIdentifier)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        // Leave double-tap-to-zoom to the map.
        for recognizer in map.subviews.flatMap({ $0.gestureRecognizers ?? [] }) + (map.gestureRecognizers ?? []) {
            if let double = recognizer as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 {
                tap.require(toFail: double)
            }
        }
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
        coordinator.apply(command, to: map)
        coordinator.syncDestination(destination, on: map)
        coordinator.syncOverlays(on: map)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ParkingMap
        private var lastCommand: UUID?
        private var drawnRevision = -1
        private var drawnSelection: String?
        private var drawnStyle: UIUserInterfaceStyle = .unspecified
        private var parkingOverlays: [MKOverlay] = []
        private var selectionOverlays: [MKOverlay] = []
        private var pointAnnotations: [PointItemAnnotation] = []
        private var destinationAnnotation: MKPointAnnotation?

        /// How close (in points) a tap must be to a line to select it.
        private static let tapTolerance: CGFloat = 24

        init(_ parent: ParkingMap) {
            self.parent = parent
        }

        // MARK: Camera

        func apply(_ command: MapCommand?, to map: MKMapView) {
            guard let command, command.id != lastCommand else { return }
            lastCommand = command.id
            switch command.kind {
            case .region(let center, let metres):
                let region = MKCoordinateRegion(center: center, latitudinalMeters: metres, longitudinalMeters: metres)
                map.setRegion(map.regionThatFits(region), animated: command.animated)
            case .userLocation:
                map.setUserTrackingMode(.follow, animated: command.animated)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionChange(mapView.region.boundingBox)
        }

        // MARK: Destination marker

        func syncDestination(_ destination: ResolvedPlace?, on map: MKMapView) {
            if let existing = destinationAnnotation {
                if let destination, existing.title == destination.name,
                    existing.coordinate.latitude == destination.coordinate.latitude,
                    existing.coordinate.longitude == destination.coordinate.longitude
                {
                    return
                }
                map.removeAnnotation(existing)
                destinationAnnotation = nil
            }
            guard let destination else { return }
            let annotation = MKPointAnnotation()
            annotation.coordinate = destination.coordinate
            annotation.title = destination.name
            map.addAnnotation(annotation)
            destinationAnnotation = annotation
        }

        // MARK: Overlays

        func syncOverlays(on map: MKMapView) {
            let style = map.traitCollection.userInterfaceStyle
            let itemsChanged = parent.revision != drawnRevision || style != drawnStyle
            if itemsChanged {
                drawnRevision = parent.revision
                drawnStyle = style
                rebuildParkingOverlays(on: map)
            }
            if itemsChanged || parent.selectedID != drawnSelection {
                drawnSelection = parent.selectedID
                rebuildSelection(on: map)
            }
        }

        private func rebuildParkingOverlays(on map: MKMapView) {
            map.removeOverlays(parkingOverlays)
            map.removeAnnotations(pointAnnotations)
            parkingOverlays = []
            pointAnnotations = []

            // Zones first, so they sit underneath: context, never kerb lines.
            let zonePolygons = parent.zones.flatMap { zone in zone.polygons.compactMap(Self.polygon) }
            if !zonePolygons.isEmpty {
                parkingOverlays.append(StyledMultiPolygon(zonePolygons, role: .zone))
            }

            var lines: [LineStyleKey: [MKPolyline]] = [:]
            var areas: [ParkingStatus: [MKPolygon]] = [:]
            for item in parent.items {
                switch item.shape {
                case .line(let parts):
                    let key = LineStyleKey(status: item.status, lowerConfidence: item.status.isAllowed && item.confidence < .high)
                    for part in parts where part.count > 1 {
                        var coordinates = part.map(\.clLocation)
                        lines[key, default: []].append(MKPolyline(coordinates: &coordinates, count: coordinates.count))
                    }
                case .area(let polygons):
                    areas[item.status, default: []].append(contentsOf: polygons.compactMap(Self.polygon))
                case .point(let coordinate):
                    pointAnnotations.append(PointItemAnnotation(id: item.id, coordinate: coordinate.clLocation, status: item.status, name: item.name))
                }
            }
            for (status, polygons) in areas {
                parkingOverlays.append(StyledMultiPolygon(polygons, role: .area(status)))
            }
            // Draw the statuses that matter most last, so they sit on top.
            for key in lines.keys.sorted(by: { $0.drawOrder < $1.drawOrder }) {
                parkingOverlays.append(StyledMultiPolyline(lines[key] ?? [], key: key))
            }
            map.addOverlays(parkingOverlays, level: .aboveRoads)
            map.addAnnotations(pointAnnotations)
        }

        /// The selected item is drawn again on top, with a light casing.
        private func rebuildSelection(on map: MKMapView) {
            map.removeOverlays(selectionOverlays)
            selectionOverlays = []
            for annotation in pointAnnotations {
                (map.view(for: annotation) as? PointItemView)?.setSelectedAppearance(annotation.id == parent.selectedID)
            }
            guard let id = parent.selectedID, let item = parent.items.first(where: { $0.id == id }) else { return }
            switch item.shape {
            case .line(let parts):
                let polylines = parts.filter { $0.count > 1 }.map { part -> MKPolyline in
                    var coordinates = part.map(\.clLocation)
                    return MKPolyline(coordinates: &coordinates, count: coordinates.count)
                }
                let key = LineStyleKey(status: item.status, lowerConfidence: item.status.isAllowed && item.confidence < .high)
                selectionOverlays = [
                    StyledMultiPolyline(polylines, key: key, selection: .casing),
                    StyledMultiPolyline(polylines, key: key, selection: .highlight),
                ]
            case .area(let polygons):
                selectionOverlays = [StyledMultiPolygon(polygons.compactMap(Self.polygon), role: .selectedArea(item.status))]
            case .point:
                break
            }
            map.addOverlays(selectionOverlays, level: .aboveRoads)
        }

        private static func polygon(_ rings: [[Coordinate]]) -> MKPolygon? {
            guard let outer = rings.first, outer.count > 2 else { return nil }
            var coordinates = outer.map(\.clLocation)
            let holes = rings.dropFirst().filter { $0.count > 2 }.map { ring -> MKPolygon in
                var inner = ring.map(\.clLocation)
                return MKPolygon(coordinates: &inner, count: inner.count)
            }
            return MKPolygon(coordinates: &coordinates, count: coordinates.count, interiorPolygons: holes)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let traits = mapView.traitCollection
            if let lines = overlay as? StyledMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: lines)
                let style = ParkingStyle.style(for: lines.key.status)
                let stroke = ParkingStyle.stroke(
                    for: lines.key.status, confidence: lines.key.lowerConfidence ? .medium : .high,
                    selected: lines.selection != nil)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                switch lines.selection {
                case .casing:
                    renderer.strokeColor = .white
                    renderer.lineWidth = style.lineWidth + 7
                default:
                    renderer.strokeColor = UIColor(style.color).resolvedColor(with: traits)
                    renderer.lineWidth = stroke.lineWidth
                    renderer.lineDashPattern = stroke.dash.isEmpty ? nil : stroke.dash.map { NSNumber(value: Double($0)) }
                }
                return renderer
            }
            if let polygons = overlay as? StyledMultiPolygon {
                let renderer = MKMultiPolygonRenderer(multiPolygon: polygons)
                switch polygons.role {
                case .zone:
                    let color = UIColor(Palette.zone).resolvedColor(with: traits)
                    renderer.fillColor = color.withAlphaComponent(0.05)
                    renderer.strokeColor = color.withAlphaComponent(0.55)
                    renderer.lineWidth = 1.5
                    renderer.lineDashPattern = [6, 4]
                case .area(let status), .selectedArea(let status):
                    // Rules recorded as an area are shaded, never drawn as a kerb line.
                    let selected = { if case .selectedArea = polygons.role { true } else { false } }()
                    let color = UIColor(ParkingStyle.style(for: status).color).resolvedColor(with: traits)
                    renderer.fillColor = color.withAlphaComponent(selected ? 0.35 : 0.18)
                    renderer.strokeColor = color
                    renderer.lineWidth = selected ? 3 : 1.5
                    renderer.lineDashPattern = [4, 4]
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? PointItemAnnotation else { return nil }  // default views otherwise
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PointItemView.reuseIdentifier, for: point)
            (view as? PointItemView)?.configure(status: point.status, selected: point.id == parent.selectedID)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let point = annotation as? PointItemAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            parent.onSelect(point.id)
        }

        // MARK: Tap selection

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            parent.onSelect(hitTest(recognizer.location(in: map), on: map))
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        /// The item nearest a tap, if any is within reach.
        private func hitTest(_ point: CGPoint, on map: MKMapView) -> String? {
            var best: (id: String, distance: CGFloat)?
            func consider(_ id: String, _ distance: CGFloat) {
                if distance <= Self.tapTolerance, distance < (best?.distance ?? .infinity) { best = (id, distance) }
            }
            func screen(_ coordinate: Coordinate) -> CGPoint { map.convert(coordinate.clLocation, toPointTo: map) }
            for item in parent.items {
                switch item.shape {
                case .line(let parts):
                    for part in parts {
                        consider(item.id, Geometry2D.distance(from: point, toPolyline: part.map(screen)))
                    }
                case .point(let coordinate):
                    let position = screen(coordinate)
                    consider(item.id, hypot(position.x - point.x, position.y - point.y))
                case .area(let polygons):
                    for rings in polygons {
                        // Lines win over the areas beneath them.
                        if Geometry2D.contains(point, polygon: (rings.first ?? []).map(screen)) {
                            consider(item.id, Self.tapTolerance - 1)
                        }
                    }
                }
            }
            return best?.id
        }
    }
}

// MARK: Overlay and annotation types

/// Lines sharing a style are drawn as one overlay.
struct LineStyleKey: Hashable {
    let status: ParkingStatus
    /// Allowed, but with less than high confidence: drawn dashed.
    let lowerConfidence: Bool

    /// Higher values are drawn later, so they sit on top.
    var drawOrder: Int {
        let base: Int
        switch status {
        case .unknown: base = 0
        case .specialist: base = 1
        case .conditional: base = 2
        case .allowedPaid: base = 3
        case .allowedFree: base = 4
        case .prohibited: base = 5
        }
        return base * 2 + (lowerConfidence ? 0 : 1)
    }
}

final class StyledMultiPolyline: MKMultiPolyline {
    enum Selection { case casing, highlight }
    private(set) var key = LineStyleKey(status: .unknown, lowerConfidence: false)
    private(set) var selection: Selection?

    convenience init(_ polylines: [MKPolyline], key: LineStyleKey, selection: Selection? = nil) {
        self.init(polylines)
        self.key = key
        self.selection = selection
    }
}

final class StyledMultiPolygon: MKMultiPolygon {
    enum Role { case zone, area(ParkingStatus), selectedArea(ParkingStatus) }
    private(set) var role = Role.zone

    convenience init(_ polygons: [MKPolygon], role: Role) {
        self.init(polygons)
        self.role = role
    }
}

/// A rule the source records only as a point.
final class PointItemAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let status: ParkingStatus
    let title: String?

    init(id: String, coordinate: CLLocationCoordinate2D, status: ParkingStatus, name: String) {
        self.id = id
        self.coordinate = coordinate
        self.status = status
        title = name
    }
}

final class PointItemView: MKAnnotationView {
    static let reuseIdentifier = "point-item"
    private let dot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 28, height: 28)  // a comfortable tap target
        dot.layer.borderColor = UIColor.white.cgColor
        dot.isUserInteractionEnabled = false
        addSubview(dot)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(status: ParkingStatus, selected: Bool) {
        let style = ParkingStyle.style(for: status)
        dot.backgroundColor = UIColor(style.color)
        accessibilityLabel = "\(annotation?.title.flatMap { $0 } ?? "Parking rule"): \(style.label)"
        setSelectedAppearance(selected)
    }

    func setSelectedAppearance(_ selected: Bool) {
        let size: CGFloat = selected ? 20 : 14
        dot.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        dot.layer.cornerRadius = size / 2
        dot.layer.borderWidth = selected ? 4 : 2
    }
}

/// Screen-space geometry for hit testing.
enum Geometry2D {
    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else {
            return points.first.map { hypot($0.x - point.x, $0.y - point.y) } ?? .infinity
        }
        var best = CGFloat.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            best = min(best, distance(from: point, toSegment: a, b))
        }
        return best
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Ray-casting point-in-polygon test.
    static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension MKCoordinateRegion {
    var boundingBox: BoundingBox {
        BoundingBox(
            west: center.longitude - span.longitudeDelta / 2, south: center.latitude - span.latitudeDelta / 2,
            east: center.longitude + span.longitudeDelta / 2, north: center.latitude + span.latitudeDelta / 2)
    }
}

import LocisKit
import MapKit
import SwiftUI

/// The Apple Map with parking overlays, and tap-to-select on those overlays.
struct ParkingMap: View {
    let model: ParkingMapModel
    @Binding var position: MapCameraPosition
    let destination: ResolvedPlace?
    let showsUserLocation: Bool

    /// How close (in points) a tap must be to a line to select it.
    private static let tapTolerance: CGFloat = 24

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if showsUserLocation { UserAnnotation() }

                if let destination {
                    Marker(destination.name, systemImage: "mappin", coordinate: destination.coordinate)
                        .tint(.primary)
                }

                // Zones are context, drawn faintly and never as kerb lines.
                ForEach(model.zones) { zone in
                    ForEach(Array(zone.polygons.enumerated()), id: \.offset) { _, rings in
                        if let outer = rings.first {
                            MapPolygon(coordinates: outer.map(\.clLocation))
                                .foregroundStyle(Palette.zone.opacity(0.05))
                                .stroke(Palette.zone.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                    }
                }

                ForEach(model.visibleItems) { item in
                    content(for: item, selected: false)
                }

                // The selected item is drawn again on top, with a light casing.
                if let selected = model.visibleItems.first(where: { $0.id == model.selectedID }) {
                    content(for: selected, selected: true)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                model.viewportChanged(context.region.boundingBox)
            }
            .onTapGesture { point in
                model.selectedID = hitTest(point, proxy: proxy)
            }
        }
    }

    @MapContentBuilder
    private func content(for item: MapItem, selected: Bool) -> some MapContent {
        let style = ParkingStyle.style(for: item.status)
        switch item.shape {
        case .line(let parts):
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if selected {
                    // A light casing so the selected line stands out on any map colour.
                    MapPolyline(coordinates: part.map(\.clLocation))
                        .stroke(.white, style: StrokeStyle(lineWidth: style.lineWidth + 7, lineCap: .round))
                }
                MapPolyline(coordinates: part.map(\.clLocation))
                    .stroke(style.color, style: ParkingStyle.stroke(for: item.status, confidence: item.confidence, selected: selected))
            }
        case .area(let polygons):
            // Rules recorded as an area are shaded, never drawn as a kerb line.
            ForEach(Array(polygons.enumerated()), id: \.offset) { _, rings in
                if let outer = rings.first {
                    MapPolygon(coordinates: outer.map(\.clLocation))
                        .foregroundStyle(style.color.opacity(selected ? 0.35 : 0.18))
                        .stroke(style.color, style: StrokeStyle(lineWidth: selected ? 3 : 1.5, dash: [4, 4]))
                }
            }
        case .point(let coordinate):
            Annotation(item.name, coordinate: coordinate.clLocation, anchor: .center) {
                Circle()
                    .fill(style.color)
                    .stroke(.white, lineWidth: selected ? 4 : 2)
                    .frame(width: selected ? 20 : 14, height: selected ? 20 : 14)
                    .accessibilityHidden(true)
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: Hit testing

    /// The item nearest a tap, if any is within reach.
    private func hitTest(_ point: CGPoint, proxy: MapProxy) -> String? {
        var best: (id: String, distance: CGFloat)?
        func consider(_ id: String, _ distance: CGFloat) {
            if distance <= Self.tapTolerance, distance < (best?.distance ?? .infinity) { best = (id, distance) }
        }
        for item in model.visibleItems {
            switch item.shape {
            case .line(let parts):
                for part in parts {
                    let points = part.compactMap { proxy.convert($0.clLocation, to: .local) }
                    consider(item.id, Geometry2D.distance(from: point, toPolyline: points))
                }
            case .point(let coordinate):
                if let screen = proxy.convert(coordinate.clLocation, to: .local) {
                    consider(item.id, hypot(screen.x - point.x, screen.y - point.y))
                }
            case .area(let polygons):
                for rings in polygons {
                    let points = (rings.first ?? []).compactMap { proxy.convert($0.clLocation, to: .local) }
                    // Lines win over the areas beneath them.
                    if Geometry2D.contains(point, polygon: points) { consider(item.id, Self.tapTolerance - 1) }
                }
            }
        }
        return best?.id
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

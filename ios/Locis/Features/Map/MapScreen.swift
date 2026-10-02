import LocisKit
import MapKit
import SwiftUI

/// The main screen: a map with parking rules drawn along the kerbs.
struct MapScreen: View {
    @Environment(AppModel.self) private var app

    @State private var command: MapCommand?
    @State private var search = SearchViewModel(service: MapKitPlaceSearch())
    @State private var location = LocationService()
    @State private var showingStayEditor = false
    @State private var showingSettings = false
    @State private var showingLegend = false
    @State private var didSetInitialPosition = false
    @FocusState private var searchFocused: Bool

    private var model: ParkingMapModel { app.map }

    var body: some View {
        @Bindable var model = app.map
        ZStack(alignment: .top) {
            ParkingMap(
                items: model.visibleItems, zones: model.zones,
                // The filter changes what is drawn without changing the model's items.
                revision: model.itemsRevision &* 8 &+ (MapFilter.allCases.firstIndex(of: model.filter) ?? 0),
                selectedID: model.selectedID, destination: search.destination,
                showsUserLocation: location.isAuthorized, command: command,
                onRegionChange: { model.viewportChanged($0) },
                onSelect: { model.selectedID = $0 }
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                if model.isDemo { DemoBanner() }
                SearchField(search: search, focused: $searchFocused) { place in
                    show(place)
                }
                if !searchFocused {
                    HStack(spacing: 8) {
                        StayControl(selection: model.selection) { showingStayEditor = true }
                        FilterMenu(filter: $model.filter)
                    }
                    if let notice = model.notice {
                        NoticePill(text: notice.message, isLoading: false)
                    } else if model.phase == .loading || model.isEvaluating {
                        NoticePill(text: "Loading parking rules", isLoading: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !searchFocused {
                HStack(alignment: .bottom) {
                    LegendButton(isExpanded: $showingLegend)
                    Spacer()
                    VStack(spacing: 10) {
                        MapButton(symbol: "gearshape", label: "Settings") { showingSettings = true }
                        MapButton(
                            symbol: location.isDenied ? "location.slash" : "location", label: "Show my location"
                        ) {
                            location.requestLocation()
                            followUserIfPossible()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        // One sheet at a time: opening the time editor or settings replaces the details.
        .sheet(item: activeSheet, onDismiss: { app.settingsChanged() }) { sheet in
            switch sheet {
            case .stay:
                StayEditorSheet(selection: $model.selection)
                    .presentationDetents([.medium, .large])
            case .settings:
                SettingsScreen()
                    .environment(app)
            case .detail(let detail):
                ParkingDetailSheet(detail: detail, selection: model.selection, isDemo: model.isDemo)
                    .presentationDetents([.fraction(0.42), .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                    // An opaque background: the rules must stay readable over any map.
                    .presentationBackground(Color(.systemBackground))
            }
        }
        .onAppear(perform: setInitialPosition)
        .onChange(of: location.authorization) { followUserIfPossible() }
    }

    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if showingStayEditor { return .stay }
                if showingSettings { return .settings }
                if let id = model.selectedID, let detail = model.detail(for: id) { return .detail(detail) }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if showingStayEditor {
                    showingStayEditor = false
                } else if showingSettings {
                    showingSettings = false
                } else {
                    model.selectedID = nil
                }
            })
    }

    private func setInitialPosition() {
        guard !didSetInitialPosition else { return }
        didSetInitialPosition = true
        setPosition(for: app.source)
    }

    private func setPosition(for source: DataSourceConfiguration) {
        var centre: CLLocationCoordinate2D
        var metres: CLLocationDistance
        if source.isDemo {
            // The fictional demo quarter.
            centre = CLLocationCoordinate2D(latitude: DemoData.centre.latitude, longitude: DemoData.centre.longitude)
            metres = 520
        } else {
            centre = CLLocationCoordinate2D(latitude: 51.5079, longitude: -0.1277)  // Charing Cross
            metres = 900
        }
        #if DEBUG
        if let start = AppConfiguration.debugStart {
            centre = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
            metres = 600
        }
        #endif
        command = MapCommand(kind: .region(center: centre, metres: metres), animated: false)
    }

    private func show(_ place: ResolvedPlace) {
        searchFocused = false
        model.selectedID = nil
        // Neighbourhood level: close enough to read kerb rules around the destination.
        command = MapCommand(kind: .region(center: place.coordinate, metres: 700))
    }

    private func followUserIfPossible() {
        guard location.wantsToFollowUser, location.isAuthorized else { return }
        location.wantsToFollowUser = false
        command = MapCommand(kind: .userLocation)
    }
}

/// The sheet currently shown over the map.
enum ActiveSheet: Identifiable, Equatable {
    case stay
    case settings
    case detail(FeatureDetail)

    var id: String {
        switch self {
        case .stay: "stay"
        case .settings: "settings"
        case .detail(let detail): "detail-\(detail.feature.id)"
        }
    }
}

// MARK: Small overlay pieces

struct DemoBanner: View {
    var body: some View {
        Label("Demo data. These streets and rules are made up.", systemImage: "testtube.2")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Palette.demoBanner, in: .capsule)
            .accessibilityAddTraits(.isStaticText)
    }
}

struct NoticePill: View {
    let text: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(text)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct MapButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .accessibilityLabel(label)
    }
}

struct FilterMenu: View {
    @Binding var filter: MapFilter

    var body: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(MapFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Section {
                Text("Filters only hide lines. Roads with no line have no data, not free parking.")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                Text(filter.title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
        .accessibilityLabel("Filter: \(filter.title)")
    }
}

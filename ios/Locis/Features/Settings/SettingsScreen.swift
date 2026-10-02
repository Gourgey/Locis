import LocisKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Vehicle", selection: $settings.vehicleType) {
                        ForEach(VehicleType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    Toggle("Blue Badge holder", isOn: $settings.blueBadge)
                } header: {
                    Text("Your vehicle")
                } footer: {
                    Text(
                        "Used to work out which bays you can use. Permit bays are always shown as conditional, because the app can't confirm which permits you hold. Blue Badge concessions on yellow lines and in paid bays vary by council and are not applied."
                    )
                }

                if app.source.isDemo {
                    // Only development builds with no data address configured get here.
                    Section {
                        LabeledContent("Data", value: "Demo only")
                    } header: {
                        Text("Parking data")
                    } footer: {
                        Text("This build has no live data source configured, so it shows made-up demo streets.")
                    }
                }

                Section {
                    NavigationLink("About and data sources") { AboutScreen() }
                    if let policy = AppConfiguration.privacyPolicyURL {
                        Link("Privacy policy", destination: policy)
                    }
                } footer: {
                    Text(AppConfiguration.disclaimer)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Attribution, licence, data freshness and the parking-information disclaimer.
struct AboutScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let state = app.map.manifestState
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(.rect(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppConfiguration.appName).font(.title2.weight(.semibold))
                        Text("Version \(AppConfiguration.version)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(
                    "\(AppConfiguration.appName) shows whether you may legally park on a section of kerb for the whole of the time you choose. It does not know whether a space is empty."
                )
                Text(AppConfiguration.disclaimer)
            }

            Section("Data sources") {
                Text("Parking rules come from the Department for Transport's Digital Traffic Regulation Order (D-TRO) service, published by local traffic authorities.")
                Link("Department for Transport D-TRO", destination: AppConfiguration.dtroURL)
                Text(AppConfiguration.attribution)
                Link("Open Government Licence v3.0", destination: AppConfiguration.licenceURL)
                Text("Bank holiday dates come from GOV.UK. Maps and search are provided by Apple.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("This dataset") {
                if let state {
                    let manifest = state.manifest
                    if manifest.synthetic {
                        Label("Synthetic demo data. Not real parking rules.", systemImage: "testtube.2")
                            .foregroundStyle(Palette.specialist)
                    }
                    LabeledContent("Last synced with D-TRO", value: Self.date(manifest.lastSync))
                    LabeledContent("Published", value: Self.date(manifest.generatedAt))
                    if state.isFromCache {
                        LabeledContent("Saved on this device", value: Self.date(state.fetchedAt))
                    }
                    LabeledContent("Orders", value: manifest.counts.records.formatted())
                    LabeledContent("Kerb rules", value: manifest.counts.features.formatted())
                    if let versions = manifest.counts.bySchemaVersion, !versions.isEmpty {
                        LabeledContent("D-TRO schema", value: versions.keys.sorted().joined(separator: ", "))
                    }
                    if let transformation = manifest.transformation {
                        LabeledContent("Coordinates", value: transformation)
                    }
                } else {
                    Text("No dataset loaded yet.").foregroundStyle(.secondary)
                }
            }

            if let authorities = state?.manifest.authorities, !authorities.isEmpty {
                Section {
                    ForEach(authorities.prefix(60)) { authority in
                        LabeledContent(authority.name, value: authority.features.formatted())
                    }
                } header: {
                    Text("Authorities with published rules")
                } footer: {
                    Text("Many authorities have not published their orders yet. Where there is no data the map shows nothing, which never means parking is unrestricted.")
                }
            }

            Section("Privacy") {
                Text("No account, no adverts, no tracking. Your location is used only on this device to centre the map. Your searches go to Apple Maps and are not stored by the app.")
                if let policy = AppConfiguration.privacyPolicyURL {
                    Link("Privacy policy", destination: policy)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not recorded"
    }
}

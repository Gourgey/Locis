import LocisKit
import SwiftUI

/// The always-visible summary of the chosen arrival and leaving times.
struct StayControl: View {
    let selection: StaySelection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                column("Arrive", StaySelection.label(for: selection.arrival))
                Divider().frame(height: 30).padding(.horizontal, 10)
                column("Leave", StaySelection.label(for: selection.departure))
                Spacer(minLength: 4)
                Image(systemName: selection.problem == nil ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(selection.problem == nil ? Color.secondary : Palette.prohibited)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Arrive \(StaySelection.label(for: selection.arrival)), leave \(StaySelection.label(for: selection.departure))")
        .accessibilityHint("Double tap to change your parking times")
        .accessibilityAddTraits(.isButton)
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// Sheet for choosing arrival and leaving times.
struct StayEditorSheet: View {
    @Binding var selection: StaySelection
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StaySelection

    init(selection: Binding<StaySelection>) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
    }

    private static let london = TimeZone(identifier: "Europe/London")!
    private static let quickHours = [1, 2, 4, 8]

    /// The stay length as one of the quick choices, when it matches one exactly.
    private var quickLength: Binding<Int?> {
        Binding(
            get: { Self.quickHours.first { Double($0) * 3600 == draft.duration } },
            set: { hours in
                if let hours { draft.departure = draft.arrival.addingTimeInterval(Double(hours) * 3600) }
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Arrive",
                        selection: Binding(get: { draft.arrival }, set: { draft.moveArrival(to: $0) }))
                    DatePicker("Leave", selection: $draft.departure, in: draft.arrival...)
                } footer: {
                    if let problem = draft.problem {
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.prohibited)
                    } else {
                        Text("Length of stay: \(Describe.duration(Int(draft.duration))). Times are UK time.")
                    }
                }
                Section("Length of stay") {
                    Picker("Length of stay", selection: quickLength) {
                        ForEach(Self.quickHours, id: \.self) { hours in
                            Text("\(hours) hr").tag(Optional(hours))
                        }
                    }
                    .pickerStyle(.segmented)
                    Button("Arrive now") { draft = .suggested() }
                }
            }
            .environment(\.timeZone, Self.london)
            .navigationTitle("Your stay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selection = draft
                        dismiss()
                    }
                    .disabled(draft.problem != nil)
                }
            }
        }
    }
}

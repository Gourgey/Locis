import SwiftUI

/// The search bar and its suggestion list.
struct SearchField: View {
    @Bindable var search: SearchViewModel
    var focused: FocusState<Bool>.Binding
    let onResolved: (ResolvedPlace) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for an address or place", text: $search.query)
                    .focused(focused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { if let place = await search.submit() { onResolved(place) } }
                    }
                if search.status == .resolving {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty || search.destination != nil {
                    Button {
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
                if focused.wrappedValue {
                    Button("Cancel") { focused.wrappedValue = false }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)

            if focused.wrappedValue {
                if let message = search.message {
                    Divider()
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else if !search.suggestions.isEmpty {
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(search.suggestions) { suggestion in
                                Button {
                                    Task { if let place = await search.choose(suggestion) { onResolved(place) } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title).font(.body).foregroundStyle(.primary)
                                        if !suggestion.subtitle.isEmpty {
                                            Text(suggestion.subtitle).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

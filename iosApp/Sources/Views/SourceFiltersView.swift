import SwiftUI

/// What the user picked in a source's filters, keyed by filter id. Only touched filters are
/// stored, so everything else keeps the source's own defaults.
struct SourceFilterSelections: Equatable {
    var text: [String: String] = [:]
    /// 0 off/ignored, 1 on/include, 2 exclude.
    var check: [String: Int] = [:]
    var select: [String: Int] = [:]
    var sortField: [String: Int] = [:]
    var sortAscending: [String: Bool] = [:]

    var isEmpty: Bool {
        text.isEmpty && check.isEmpty && select.isEmpty && sortField.isEmpty
    }

    /// The wire format the extension host applies before searching: one line per touched
    /// filter, "id<TAB>kind<TAB>value[<TAB>ascending]". Nil when nothing was touched.
    func encoded(for filters: [SourceFilter]) -> String? {
        var lines: [String] = []
        for filter in filters {
            switch filter.type {
                case "text":
                    if let value = text[filter.id] {
                        lines.append("\(filter.id)\ttext\t\(Self.escape(value))")
                    }
                case "check":
                    if let value = check[filter.id] {
                        lines.append("\(filter.id)\tcheck\t\(value)")
                    }
                case "select":
                    if let value = select[filter.id] {
                        lines.append("\(filter.id)\tselect\t\(value)")
                    }
                case "sort":
                    if let value = sortField[filter.id] {
                        let ascending = sortAscending[filter.id] ?? false
                        lines.append("\(filter.id)\tsort\t\(value)\t\(ascending)")
                    }
                default:
                    break
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The host URL-decodes the value, so tabs, newlines and percent signs travel encoded.
    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// Bottom sheet with a source's own search filters (genres, estado, orden…).
struct SourceFiltersSheet: View {
    let source: SourceInfo
    let installed: InstalledExtension
    @Binding var filters: [SourceFilter]
    @Binding var selections: SourceFilterSelections
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if filters.isEmpty && isLoading {
                    ProgressView("Cargando filtros…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filters.isEmpty, let error {
                    VStack(spacing: 12) {
                        EmptyStateView(
                            symbol: "line.3.horizontal.decrease.circle",
                            title: "No se pudieron cargar",
                            message: error
                        )
                        Button("Reintentar") { Task { await load(force: true) } }
                            .padding(.bottom, 32)
                    }
                } else if filters.isEmpty {
                    EmptyStateView(
                        symbol: "line.3.horizontal.decrease.circle",
                        title: "Sin filtros",
                        message: "Esta fuente no ofrece filtros de búsqueda."
                    )
                } else {
                    form
                }
            }
            .navigationTitle("Filtros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Restablecer") { selections = SourceFilterSelections() }
                        .disabled(selections.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task { await load(force: false) }
        }
    }

    // MARK: - Layout

    private struct FilterSection: Identifiable {
        let id: Int
        let title: String?
        var filters: [SourceFilter]
    }

    /// Groups follow the source's order: a header filter names the rows after it, and grouped
    /// checkboxes keep their parent's name.
    private var grouped: [FilterSection] {
        var sections: [FilterSection] = []
        var pendingTitle: String?
        for filter in filters {
            if filter.type == "note" {
                pendingTitle = filter.name
                continue
            }
            let title = filter.group ?? pendingTitle
            if var last = sections.last, last.title == title {
                last.filters.append(filter)
                sections[sections.count - 1] = last
            } else {
                sections.append(FilterSection(id: sections.count, title: title, filters: [filter]))
            }
        }
        return sections
    }

    private var form: some View {
        Form {
            ForEach(grouped) { section in
                Section(section.title ?? "") {
                    ForEach(section.filters) { filter in
                        control(filter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ filter: SourceFilter) -> some View {
        switch filter.type {
            case "text":
                TextField(filter.name, text: textBinding(filter))
            case "check":
                if filter.auxiliary == "true" {
                    triStateRow(filter)
                } else {
                    Toggle(filter.name, isOn: checkBinding(filter))
                }
            case "select":
                Picker(filter.name, selection: selectBinding(filter)) {
                    ForEach(Array((filter.options ?? []).enumerated()), id: \.offset) { index, option in
                        Text(option).tag(index)
                    }
                }
            case "sort":
                sortRows(filter)
            default:
                EmptyView()
        }
    }

    /// Include / exclude / ignore, the three-state checkbox of Mihon sources.
    private func triStateRow(_ filter: SourceFilter) -> some View {
        let value = selections.check[filter.id] ?? defaultInt(filter)
        return Button {
            selections.check[filter.id] = (value + 1) % 3
        } label: {
            HStack {
                Image(systemName: value == 1
                    ? "checkmark.square.fill"
                    : value == 2 ? "xmark.square.fill" : "square")
                    .foregroundStyle(value == 1 ? Color.accentColor : value == 2 ? Color.red : Color.secondary)
                Text(filter.name)
                    .foregroundStyle(.primary)
            }
        }
    }

    /// One row per sort option; tapping the chosen one flips the direction.
    @ViewBuilder
    private func sortRows(_ filter: SourceFilter) -> some View {
        let options = filter.options ?? []
        let selectedIndex = selections.sortField[filter.id]
            ?? filter.defaultValue.flatMap { Int($0) }
        let ascending = selections.sortAscending[filter.id] ?? (filter.auxiliary == "true")
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button {
                if selectedIndex == index {
                    selections.sortAscending[filter.id] = !ascending
                } else {
                    selections.sortAscending[filter.id] = ascending
                }
                selections.sortField[filter.id] = index
            } label: {
                HStack {
                    Text(option)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selectedIndex == index {
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private func defaultInt(_ filter: SourceFilter) -> Int {
        guard let value = filter.defaultValue else { return 0 }
        if let number = Int(value) { return number }
        return value == "true" ? 1 : 0
    }

    private func textBinding(_ filter: SourceFilter) -> Binding<String> {
        Binding(
            get: { selections.text[filter.id] ?? filter.defaultValue ?? "" },
            set: { selections.text[filter.id] = $0 }
        )
    }

    private func checkBinding(_ filter: SourceFilter) -> Binding<Bool> {
        Binding(
            get: { (selections.check[filter.id] ?? defaultInt(filter)) != 0 },
            set: { selections.check[filter.id] = $0 ? 1 : 0 }
        )
    }

    private func selectBinding(_ filter: SourceFilter) -> Binding<Int> {
        Binding(
            get: { selections.select[filter.id] ?? defaultInt(filter) },
            set: { selections.select[filter.id] = $0 }
        )
    }

    private func load(force: Bool) async {
        guard filters.isEmpty || force else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            filters = try await JVMEngine.shared.searchFilters(source: source, installed: installed)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

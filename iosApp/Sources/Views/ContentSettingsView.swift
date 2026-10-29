import SwiftUI

/// The content restriction: which extensions are allowed, the hand-picked exceptions, and
/// the button that hides this screen for good (a parental lock).
struct ContentSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var extensions: ExtensionManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingLock = false

    private var candidates: [CatalogExtension] {
        extensions.restrictedCandidates
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Extensiones permitidas", selection: $settings.contentLevel) {
                    ForEach(ContentLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Extensiones permitidas")
            } footer: {
                Text(settings.contentLevel.detail + " "
                    + NSLocalizedString("Las extensiones instaladas que queden fuera se desinstalan y sus series se ocultan.", comment: ""))
            }

            if settings.contentLevel == .exceptions {
                exceptionsSection
            }

            Section {
                Button(role: .destructive) {
                    confirmingLock = true
                } label: {
                    Label("Ocultar esta configuración", systemImage: "lock")
                }
            } footer: {
                Text("Pensado como control parental: deja la restricción elegida y quita esta pantalla de la app. Después no se puede volver a abrir.")
            }
        }
        .navigationTitle("Restricción de contenido")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "¿Ocultar la restricción de contenido?",
            isPresented: $confirmingLock,
            titleVisibility: .visible
        ) {
            Button("Ocultar para siempre", role: .destructive) {
                settings.lockContentSettings()
                dismiss()
            }
        } message: {
            Text(String(
                format: NSLocalizedString(
                    "Quedará fijo “%@” y esta configuración desaparecerá de Ajustes. No hay forma de volver a abrirla: solo borrando y reinstalando la app.",
                    comment: ""
                ),
                settings.contentLevel.title
            ))
        }
    }

    @ViewBuilder
    private var exceptionsSection: some View {
        Section {
            if extensions.catalog.isEmpty {
                Text("Agrega un repositorio en Extensiones para elegir excepciones.")
                    .foregroundStyle(.secondary)
            } else if extensions.restrictedCandidates.isEmpty {
                Text("Tus repositorios no tienen extensiones mixtas.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Buscar extensión", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ForEach(candidates) { item in
                    Toggle(isOn: binding(for: item.packageName)) {
                        HStack(spacing: 10) {
                            ExtensionIcon(url: item.iconURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.languages.map(Language.displayName).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tint(.moka)
                }
            }
        } header: {
            Text("Excepciones (\(settings.contentExceptions.count))")
        } footer: {
            Text("Solo estas extensiones mixtas se permiten, además de las normales. Las +18 nunca se permiten.")
        }
    }

    private func binding(for packageName: String) -> Binding<Bool> {
        Binding(
            get: { settings.contentExceptions.contains(packageName) },
            set: { allowed in
                if allowed {
                    settings.contentExceptions.insert(packageName)
                } else {
                    settings.contentExceptions.remove(packageName)
                }
            }
        )
    }
}

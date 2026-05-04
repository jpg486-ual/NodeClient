//  Token-based encryption UI.

import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct EncryptionSettingsView: View {
    @ObservedObject var viewModel: EncryptionSettingsViewModel
    @ObservedObject var preferences: EncryptionPreferences
    @State private var confirmReset: Bool = false
    @State private var persistInDevice: Bool = true
    @State private var isImporterPresented: Bool = false
    @State private var pendingExport: TokenExportDocument?
    @State private var isExporterPresented: Bool = false

    @MainActor
    init(
        viewModel: EncryptionSettingsViewModel,
        preferences: EncryptionPreferences? = nil
    ) {
        self.viewModel = viewModel
        self.preferences = preferences ?? EncryptionPreferences.shared
    }

    var body: some View {
        Form {
            explanationBanner

            switch viewModel.state {
            case .notConfigured:
                notConfiguredSection

            case .lockedAwaitingPassword:
                lockedSection

            case .unlocked(let since):
                unlockedSection(since: since)
            }

            preferencesSection

            if let info = viewModel.infoMessage {
                Section {
                    Label(info, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Acerca del cifrado") {
                Text("Los archivos se cifran en este dispositivo antes de subirse al servidor. El token nunca viaja al servidor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Si pierdes el token y no lo guardaste en el dispositivo ni en un archivo, los archivos cifrados quedarán inaccesibles para siempre.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Cifrado")
        .alert("¿Resetear configuración de cifrado?", isPresented: $confirmReset) {
            Button("Cancelar", role: .cancel) {}
            Button("Resetear", role: .destructive) {
                Task { await viewModel.resetEncryption() }
            }
        } message: {
            Text("Esto eliminará el token y los parámetros de derivación. Los archivos cifrados existentes quedarán inaccesibles para siempre.")
        }
        .sheet(
            item: Binding(
                get: { viewModel.freshlyGeneratedBundle },
                set: { newValue in
                    if newValue == nil {
                        viewModel.dismissFreshTokenSheet()
                    }
                }
            )
        ) { bundle in
            generatedTokenSheet(bundle: bundle)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: pendingExport,
            contentType: .json,
            defaultFilename: defaultExportFilename
        ) { result in
            if case .failure(let error) = result {
                viewModel.clearMessages()
                print("Export failed: \(error.localizedDescription)")
            }
            pendingExport = nil
        }
    }

    // MARK: - Sections

    private var explanationBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("¿Qué es el cifrado en el cliente?")
                        .font(.headline)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }

                Text("Tus archivos se cifran en este iPhone/Mac antes de subirlos. El servidor sólo guarda los bytes cifrados.")
                    .font(.callout)
                    .foregroundStyle(.primary)

                statusBadge

                Text(statusExplanation)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 6)
        }
    }

    private var statusBadge: some View {
        switch viewModel.state {
        case .notConfigured:
            return AnyView(
                Label("Sin configurar — los uploads van en claro", systemImage: "lock.open")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            )

        case .lockedAwaitingPassword:
            return AnyView(
                Label("Configurado pero token no encontrado en este dispositivo", systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.blue)
            )

        case .unlocked:
            return AnyView(
                Label("Activo — todos los uploads se cifran automáticamente", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            )
        }
    }

    private var statusExplanation: String {
        switch viewModel.state {
        case .notConfigured:
            return "Genera un token de 256 bits aleatorio o importa uno existente desde otro dispositivo."

        case .lockedAwaitingPassword:
            return "Existe configuración previa pero el token no está guardado aquí. Importa el archivo del token para reactivar el cifrado en este dispositivo."

        case .unlocked:
            return "Sesión activa. Cualquier archivo que subas se cifra automáticamente; los descargados se descifran al llegar."
        }
    }

    private var preferencesSection: some View {
        Section("Preferencias") {
            Toggle(isOn: $preferences.compressionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comprimir antes de cifrar")
                    Text("Recomendado. Reduce el tamaño que ocupa cada archivo en la red. La app omite la compresión automáticamente en archivos que ya están comprimidos (jpg, mp4, zip, pdf con imágenes).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notConfiguredSection: some View {
        Section("Activar cifrado") {
            Toggle(isOn: $persistInDevice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guardar token en este dispositivo")
                    Text("Recomendado. Se guarda en el llavero del sistema y se desbloquea automáticamente al abrir la app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await viewModel.generateToken(persistInDevice: persistInDevice) }
            } label: {
                if viewModel.isWorking {
                    ProgressView()
                } else {
                    Label("Generar token de cifrado", systemImage: "wand.and.stars")
                }
            }
            .disabled(viewModel.isWorking)

            Button {
                isImporterPresented = true
            } label: {
                Label("Importar token desde archivo", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.isWorking)
        }
    }

    private var lockedSection: some View {
        Section("Reactivar cifrado") {
            Toggle(isOn: $persistInDevice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guardar token en este dispositivo")
                    Text("Recomendado. Auto-unlock al abrir la app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isImporterPresented = true
            } label: {
                Label("Importar token desde archivo", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.isWorking)

            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Text("Resetear cifrado")
            }
        }
    }

    private func unlockedSection(since: Date) -> some View {
        Section("Cifrado activo") {
            HStack {
                Text("Activo desde")
                Spacer()
                Text(since, style: .time)
                    .foregroundStyle(.secondary)
            }

            if viewModel.exportTokenBundle() != nil {
                Button {
                    triggerExport()
                } label: {
                    Label("Exportar token a archivo", systemImage: "square.and.arrow.up")
                }
            } else {
                Label("El token no está guardado aquí — no se puede re-exportar.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Text("Resetear cifrado")
            }
        }
    }

    // MARK: - Generated token sheet

    private func generatedTokenSheet(bundle: EncryptionTokenBundle) -> some View {
        NavigationStack {
            Form {
                Section {
                    Label("Guarda este token en un lugar seguro", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Si pierdes este token y no lo guardaste en el dispositivo, los archivos cifrados serán irrecuperables.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Token") {
                    Text(bundle.token)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                Section {
                    Button {
                        triggerExport()
                    } label: {
                        Label("Exportar a archivo", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Button("Cerrar") {
                        viewModel.dismissFreshTokenSheet()
                    }
                }
            }
            .navigationTitle("Token generado")
            .platformInlineNavigationTitle()
            // Modifier duplicado dentro del sheet: SwiftUI presenta los
            // modifiers de archivo en el contexto donde están adjuntos,
            // y el `.fileExporter` del Form padre queda detrás del sheet
            // en la jerarquía modal sin disparar la presentación.
            .fileExporter(
                isPresented: $isExporterPresented,
                document: pendingExport,
                contentType: .json,
                defaultFilename: defaultExportFilename
            ) { result in
                if case .failure(let error) = result {
                    print("Export failed: \(error.localizedDescription)")
                }
                pendingExport = nil
            }
        }
    }

    // MARK: - File import / export

    private var importContentTypes: [UTType] {
        var types: [UTType] = [.json]
        if let custom = UTType(filenameExtension: "nctoken") {
            types.append(custom)
        }
        types.append(.data)
        return types
    }

    private var defaultExportFilename: String {
        "nodeclient-cifrado-\(Int(Date().timeIntervalSince1970)).json"
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task {
                    await viewModel.importToken(from: data, persistInDevice: persistInDevice)
                }
            } catch {
                Task { @MainActor in
                    viewModel.clearMessages()
                }
                print("Import read failed: \(error.localizedDescription)")
            }

        case .failure(let error):
            print("Import cancelled or failed: \(error.localizedDescription)")
        }
    }

    private func triggerExport() {
        guard let bundle = viewModel.exportTokenBundle() else { return }
        do {
            let data = try JSONEncoder().encode(bundle)
            pendingExport = TokenExportDocument(data: data)
            isExporterPresented = true
        } catch {
            print("Failed to encode bundle for export: \(error.localizedDescription)")
        }
    }
}

// MARK: - FileDocument helpers

private struct TokenExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension EncryptionTokenBundle: Identifiable {
    var id: String { token }
}

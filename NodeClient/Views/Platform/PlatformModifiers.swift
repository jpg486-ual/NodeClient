//  Modificadores cross-plataforma — concentran los #if os triviales que
//  antes estaban repetidos en cada View. Cada Vista llama a estos helpers
//  y desconoce la divergencia plataforma.

import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// `navigationBarTitleDisplayMode(.inline)` en iOS, no-op en macOS
    /// (donde el modifier no existe).
    @ViewBuilder
    func platformInlineNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    /// `.listStyle(.insetGrouped)` en iOS, `.listStyle(.inset)` en macOS.
    @ViewBuilder
    func platformGroupedListStyle() -> some View {
#if os(iOS)
        self.listStyle(.insetGrouped)
#else
        self.listStyle(.inset)
#endif
    }

    /// Modificadores estándar para campos identificador (URL, username,
    /// código de invitación). En iOS aplica `textInputAutocapitalization(.never)`,
    /// `autocorrectionDisabled(true)` y opcionalmente `keyboardType(.URL)`.
    /// En macOS no-op porque AppKit ya respeta los inputs textuales.
    @ViewBuilder
    func platformIdentifierField(_ kind: PlatformIdentifierFieldKind = .general) -> some View {
#if os(iOS)
        switch kind {
        case .general:
            self
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

        case .url:
            self
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
        }
#else
        self
#endif
    }

    /// Searchable con placement adaptado por plataforma:
    /// - iOS usa `navigationBarDrawer(displayMode: .always)` para que la
    ///   barra de búsqueda esté siempre visible bajo el title.
    /// - macOS usa `.automatic` que la integra en la toolbar nativa.
    func platformSearchable(text: Binding<String>) -> some View {
#if os(iOS)
        self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always))
#else
        self.searchable(text: text)
#endif
    }

    /// Variante de `platformSearchable` con `.automatic` en iOS — útil
    /// cuando la View no quiere forzar el drawer (ej: FavoritesView).
    func platformSearchableAutomatic(text: Binding<String>) -> some View {
#if os(iOS)
        self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic))
#else
        self.searchable(text: text)
#endif
    }
}

enum PlatformIdentifierFieldKind {
    case general
    case url
}

/// ViewModifier de pull-to-refresh: aplica `.refreshable` en iOS, no-op
/// en macOS (donde no hay gesture pull). Usado por FavoritesView y otras
/// listas sin toolbar refresh button propio.
struct PlatformPullToRefreshModifier: ViewModifier {
    let onRefresh: () async -> Void

    func body(content: Content) -> some View {
#if os(iOS)
        content.refreshable {
            await onRefresh()
        }
#else
        content
#endif
    }
}

/// ViewModifier que encapsula la combinación `.refreshable + .searchable`
/// usada por las vistas tipo navegador (FilesView). En iOS el pull-to-
/// refresh es nativo y la search bar va en el drawer; en macOS no hay
/// gesture pull (hay un botón Refresh en la toolbar) y el search field
/// va en la toolbar nativa.
struct PlatformFolderEnhancementsModifier: ViewModifier {
    @Binding var searchText: String
    let onRefresh: () async -> Void

    func body(content: Content) -> some View {
#if os(iOS)
        content
            .refreshable {
                await onRefresh()
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
#else
        content
            .searchable(text: $searchText)
#endif
    }
}

/// Acepta drops de archivos desde Finder (o cualquier source NSItemProvider
/// con `kUTTypeFileURL`) en macOS. iOS la deja como no-op porque su
/// integración nativa con Files.app pasa por la File Provider extension
/// y el FAB local cubre el caso "subir desde la propia app".
///
/// Visual feedback: borde + tinta acentuados cuando `isTargeted == true`.
/// El handler recibe sólo URLs de regular-files (las carpetas se filtran
/// y se reporta vía `onRejectedFolders`); el bulk upload secuencial vive
/// en el ViewModel (no aquí) para mantener el modifier puramente UI.
struct PlatformFolderDropTargetModifier: ViewModifier {
    /// Callback con las URLs aceptadas. Se ejecuta en el MainActor (los
    /// drops llegan ya marshalled por SwiftUI). El callback es `@escaping`
    /// porque se invoca de forma asíncrona tras `loadObject`.
    let onDrop: ([URL]) -> Void
    /// Callback opcional cuando el usuario soltó al menos una carpeta.
    /// Útil para que la View muestre un status "Las carpetas no se suben".
    let onRejectedFolders: (() -> Void)?

    init(onDrop: @escaping ([URL]) -> Void, onRejectedFolders: (() -> Void)? = nil) {
        self.onDrop = onDrop
        self.onRejectedFolders = onRejectedFolders
    }

    func body(content: Content) -> some View {
#if os(macOS)
        content.modifier(MacOSDropTargetImpl(onDrop: onDrop, onRejectedFolders: onRejectedFolders))
#else
        content
#endif
    }
}

#if os(macOS)
private struct MacOSDropTargetImpl: ViewModifier {
    let onDrop: ([URL]) -> Void
    let onRejectedFolders: (() -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.accentColor.opacity(0.08))
                        .overlay(alignment: .center) {
                            Label("Soltar para subir aquí", systemImage: "arrow.down.doc")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleProviders(providers)
                return true
            }
    }

    /// Cada provider entrega su URL de forma asíncrona via `loadObject`.
    /// Acumulamos en un buffer `actor`-safe (contains `urls` + `rejected`
    /// flags) y disparamos el callback cuando todos hayan resuelto. Si
    /// alguno apunta a un directory, lo descartamos y marcamos `rejected`.
    @MainActor
    private func handleProviders(_ providers: [NSItemProvider]) {
        let total = providers.count
        guard total > 0 else { return }
        let buffer = DropBuffer()
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    let isFolder = (url.flatMap { Self.isDirectory(at: $0) }) ?? false
                    let accepted = (isFolder ? nil : url)
                    buffer.append(accepted: accepted, rejectedFolder: isFolder)
                    if buffer.count == total {
                        let drained = buffer.drain()
                        if !drained.urls.isEmpty {
                            onDrop(drained.urls)
                        }
                        if drained.hadRejectedFolder {
                            onRejectedFolders?()
                        }
                    }
                }
            }
        }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

@MainActor
private final class DropBuffer {
    private(set) var urls: [URL] = []
    private(set) var hadRejectedFolder = false
    private(set) var count = 0

    func append(accepted: URL?, rejectedFolder: Bool) {
        count += 1
        if let accepted { urls.append(accepted) }
        if rejectedFolder { hadRejectedFolder = true }
    }

    func drain() -> (urls: [URL], hadRejectedFolder: Bool) {
        defer {
            urls.removeAll()
            hadRejectedFolder = false
            count = 0
        }
        return (urls, hadRejectedFolder)
    }
}
#endif

extension View {
    /// Aplica `PlatformFolderDropTargetModifier`. macOS-only en runtime;
    /// iOS lo deja transparente.
    func platformFolderDropTarget(
        onDrop: @escaping ([URL]) -> Void,
        onRejectedFolders: (() -> Void)? = nil
    ) -> some View {
        modifier(PlatformFolderDropTargetModifier(onDrop: onDrop, onRejectedFolders: onRejectedFolders))
    }
}

import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(ViewState.self) private var view

    var body: some View {
        @Bindable var library = library
        @Bindable var view = view
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
        }
        .inspector(isPresented: $view.showInspector) {
            Group {
                if let item = library.selected, item.planned != nil {
                    InspectorView(item: item)
                } else {
                    Text("Selecione um documento pronto para ver perfil, estratégia e legibilidade.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            library.open(urls)
            return !urls.isEmpty
        } isTargeted: { view.dropTargeted = $0 }
        .overlay {
            if view.dropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) { noticeBanner }
    }

    @ViewBuilder private var detail: some View {
        if let item = library.selected {
            switch item.status {
            case .failed(let message):
                FailureView(item: item, message: message)
            case .analyzing where item.planned == nil:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Analisando \(item.displayName)…").font(.title3)
                    Text("A análise roda num processo separado; um PDF corrompido não derruba o app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if item.planned != nil {
                    VStack(spacing: 0) {
                        PreviewView(item: item)
                        Divider()
                        ThumbnailStrip(item: item)
                            .frame(height: 146)
                    }
                } else {
                    WelcomeView()
                }
            }
        } else {
            WelcomeView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var view = view
        ToolbarItem(placement: .principal) {
            Picker("Pré-visualização", selection: $view.mode) {
                ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Origem: página com as janelas de recorte. Mini: saída na moldura do iPad mini.")
            .accessibilityLabel("Modo de pré-visualização")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let item = library.selected { library.export(item) }
            } label: {
                Label("Exportar…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
            .disabled(!(library.selected.map { $0.planned != nil && $0.status != .converting } ?? false))
            .help("Exportar o PDF adaptado (⌘E)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                view.showInspector.toggle()
            } label: {
                Label("Inspetor", systemImage: "sidebar.trailing")
            }
            .help("Mostrar ou ocultar o inspetor")
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = library.notice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").accessibilityHidden(true)
                Text(notice).font(.callout)
                if let url = library.selected?.lastExportURL, notice.hasPrefix("Exportado") {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless)
                }
                Button {
                    library.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Fechar aviso")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(8))
                if library.notice == notice { library.notice = nil }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selectionID) {
            Section("Fila") {
                ForEach(library.items) { item in
                    SidebarRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button("Analisar de novo") { library.analyze(item) }
                            if let out = item.lastExportURL {
                                Button("Mostrar exportado no Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                            }
                            Divider()
                            Button("Remover da fila", role: .destructive) { library.remove(item) }
                        }
                }
                .onDelete { idx in idx.map { library.items[$0] }.forEach(library.remove) }
            }
        }
        .overlay {
            if library.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Arraste PDFs para cá").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                library.presentOpenPanel()
            } label: {
                Label("Abrir…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
            .help("Abrir PDFs (⌘O)")
        }
    }
}

struct SidebarRow: View {
    let item: DocumentItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(2)
                HStack(spacing: 4) {
                    statusIcon
                    Text(item.status.title)
                }
                .font(.caption)
                .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName), \(item.status.title)")
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .analyzing, .converting: ProgressView().controlSize(.mini)
        case .ready: Image(systemName: "checkmark.circle.fill")
        case .warnings: Image(systemName: "exclamationmark.triangle.fill")
        case .failed: Image(systemName: "xmark.octagon.fill")
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .ready: .green
        case .warnings: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

struct WelcomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 160, height: 160)
                .accessibilityLabel("Ícone do iPDFmini")
            Text("iPDFmini").font(.largeTitle.bold())
            Text("Arraste um PDF")
                .font(.title2)
            Text("Solte PDFs nesta janela ou no ícone do Dock. O app recorta as margens e ajusta a escala para a letra ficar legível na tela do iPad mini 7.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("Abrir…") { library.presentOpenPanel() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Menu("PDF de calibração") {
                    Button("Retrato") { library.generateCalibration(.portrait) }
                    Button("Paisagem") { library.generateCalibration(.landscape) }
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.large)
                .fixedSize()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailureView: View {
    @Environment(Library.self) private var library
    let item: DocumentItem
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Não foi possível processar \(item.displayName)").font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            HStack {
                Button("Tentar de novo") { library.analyze(item) }
                Button("Remover da fila") { library.remove(item) }
            }
            .buttonStyle(.glass)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

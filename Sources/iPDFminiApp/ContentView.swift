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
        .sheet(isPresented: Binding(get: { library.batch != nil }, set: { if !$0 { library.closeBatch() } })) {
            if let b = library.batch {
                BatchSheet(session: b)
                    .environment(library)
                    .interactiveDismissDisabled(b.phase == .running)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = library.selected {
            switch item.status {
            case .failed(let message):
                FailureView(item: item, message: message)
            case .analyzing where item.planned == nil, .waiting where item.planned == nil:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(item.status == .waiting ? "\(item.displayName) aguarda vaga para análise…"
                                                 : "Analisando \(item.displayName)…").font(.title3)
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
                            // Identidade por documento: a LazyHStack reaproveitava miniaturas do anterior.
                            .id(item.id)
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
            let urls = library.shareCandidates
            if urls.isEmpty {
                Button {} label: { Label("Compartilhar", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(true)
                    .help("Exporte ou converta um documento para compartilhar")
            } else {
                // ShareLink abre o NSSharingServicePicker nativo (AirDrop, Mail, Mensagens…).
                ShareLink(items: urls) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up.on.square")
                }
                .help(urls.count == 1 ? "Compartilhar \(urls[0].lastPathComponent)" : "Compartilhar os \(urls.count) PDFs do último lote")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                library.airDrop(library.shareCandidates)
            } label: {
                Label("AirDrop", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(library.shareCandidates.isEmpty)
            .help("Enviar por AirDrop a última exportação ou o último lote")
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
            ForEach(library.queue.groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        if let item = library.docs[entry.id] {
                            SidebarRow(item: item, included: Binding(get: { library.isIncluded(entry.id) },
                                                                     set: { library.setIncluded(entry.id, $0) }),
                                       ownSettings: library.hasOwnSettings(item),
                                       subfolder: entry.found.relativeDirectory)
                                .tag(entry.id)
                                .contextMenu { rowMenu(item) }
                        }
                    }
                } header: {
                    GroupHeader(group: group)
                }
            }
        }
        .overlay {
            if library.queue.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Arraste PDFs ou pastas para cá").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                let n = library.queue.includedCount
                Button {
                    library.beginBatch()
                } label: {
                    Label("Converter selecionados (\(n))", systemImage: "square.stack.3d.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(n == 0 || library.batch?.phase == .running)
                .help("Converte em lote os documentos marcados (⇧⌘B)")
                HStack(spacing: 8) {
                    Button {
                        library.presentOpenPanel()
                    } label: {
                        Label("Abrir…", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Abrir PDFs ou pastas (⌘O)")
                    Menu {
                        Button("Marcar todos") { library.setAllIncluded(true) }
                        Button("Desmarcar todos") { library.setAllIncluded(false) }
                        Divider()
                        Button("Remover desmarcados da fila", role: .destructive) { library.removeExcluded() }
                    } label: {
                        Label("Seleção", systemImage: "checklist")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(library.queue.entries.isEmpty)
                    .help("Marcar, desmarcar ou remover desmarcados")
                    .accessibilityLabel("Ações de seleção do lote")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(12)
        }
    }

    @ViewBuilder private func rowMenu(_ item: DocumentItem) -> some View {
        Button(library.isIncluded(item.id) ? "Desmarcar do lote" : "Incluir no lote") {
            library.setIncluded(item.id, !library.isIncluded(item.id))
        }
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Analisar de novo") { library.analyze(item) }
        if let out = item.lastExportURL {
            Button("Mostrar exportado no Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            Button("Enviar exportado por AirDrop…") { library.airDrop([out]) }
        }
        Divider()
        Button("Remover da fila", role: .destructive) { library.remove(item) }
    }
}

/// Cabeçalho da seção: pasta de origem, contagem e marcar/desmarcar todos da pasta.
struct GroupHeader: View {
    @Environment(Library.self) private var library
    let group: QueueGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text(group.title).lineLimit(1).truncationMode(.middle)
            Text(group.countLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            let busy = library.folderInRunningBatch(group)
            Button {
                library.removeFolder(group)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(busy)
            .help(busy ? "Pasta em conversão no lote: remova depois que o lote terminar"
                       : "Remover pasta da lista (os arquivos continuam no disco)")
            .accessibilityLabel("Remover pasta da lista")
            Menu {
                Button("Marcar todos desta pasta") { library.setIncluded(group: group, true) }
                Button("Desmarcar todos desta pasta") { library.setIncluded(group: group, false) }
                Divider()
                Button("Remover pasta da lista") { library.removeFolder(group) }
                    .disabled(busy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Ações da pasta \(group.title)")
        }
        .help(group.root.path(percentEncoded: false))
        .contextMenu {
            Button("Remover pasta da lista") { library.removeFolder(group) }
                .disabled(library.folderInRunningBatch(group))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pasta \(group.title), \(group.includedCount) de \(group.entries.count) incluídos")
    }
}

struct SidebarRow: View {
    let item: DocumentItem
    @Binding var included: Bool
    var ownSettings = false
    var subfolder = ""

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Incluir no lote", isOn: $included)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Incluir \(item.displayName) no lote")
                .help(included ? "Incluído no lote" : "Fora do lote")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(2)
                    .foregroundStyle(included ? .primary : .secondary)
                HStack(spacing: 4) {
                    statusIcon
                    Text(item.status.title)
                    if ownSettings {
                        Image(systemName: "slider.horizontal.3").help("Ajustes próprios")
                            .accessibilityLabel("ajustes próprios")
                    }
                    if !subfolder.isEmpty {
                        Text("· \(subfolder)").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(statusColor)
            }
            // Caixa e texto separados: combinados, ativar a linha com o VoiceOver alternava a caixa.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.displayName), \(item.status.title)\(included ? "" : ", fora do lote")\(ownSettings ? ", ajustes próprios" : "")")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .analyzing, .converting: ProgressView().controlSize(.mini)
        case .waiting: Image(systemName: "clock")
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
            Text("Arraste PDFs ou pastas")
                .font(.title2)
            Text("Solte PDFs ou pastas nesta janela ou no ícone do Dock; os PDFs das subpastas entram na fila. O app recorta as margens e ajusta a escala para a letra ficar legível na tela do iPad mini 7.")
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

import AppKit
import MiniGeometry
import SwiftUI

@main
struct IPDFMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Sem @State: no SDK do macOS 27 ele é macro (SwiftUIMacros), ausente nas Command Line Tools.
    private let library = Library.shared
    private let view = ViewState.shared

    var body: some Scene {
        // Janela única: a fila mora na lateral, não em janelas por documento.
        Window("iPDFmini", id: "main") {
            ContentView()
                .environment(library)
                .environment(view)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { AppCommands(library: library, view: view) }

        Window("Ajuda do iPDFmini", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentSize)
    }
}

/// Arquivos e pastas soltos no ícone do Dock, "Abrir com" e `open -a` chegam por aqui.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.open(urls)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let library: Library
    let view: ViewState
    @Environment(\.openWindow) private var openWindow

    private var ready: DocumentItem? {
        guard let s = library.selected, s.planned != nil, s.status != .converting else { return nil }
        return s
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Sobre o iPDFmini") { showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Abrir…") { library.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Button("Exportar…") { if let r = ready { library.export(r) } }
                .keyboardShortcut("e")
                .disabled(ready == nil)
            Button("Exportar e enviar por AirDrop…") { if let r = ready { library.export(r, thenAirDrop: true) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(ready == nil)
            Button(library.sendTargets.count > 1 ? "Enviar \(library.sendTargets.count) marcados para o iPad"
                                                   : "Enviar para o iPad") { library.sendToIPad() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!library.canSendToIPad)
            Divider()
            Button("Converter selecionados (\(library.queue.includedCount))…") { library.beginBatch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(library.queue.includedCount == 0 || library.batch != nil)
            Button("Marcar todos para o lote") { library.setAllIncluded(true) }
                .disabled(library.queue.entries.isEmpty)
            Button("Desmarcar todos do lote") { library.setAllIncluded(false) }
                .disabled(library.queue.entries.isEmpty)
            Button("Remover desmarcados da fila") { library.removeExcluded() }
                .disabled(library.queue.entries.allSatisfy(\.included))
            Divider()
            Menu("Gerar PDF de calibração…") {
                Button("Retrato") { library.generateCalibration(.portrait) }
                Button("Paisagem") { library.generateCalibration(.landscape) }
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Origem") { view.mode = .source }.keyboardShortcut("1")
            Button("Mini") { view.mode = .mini }.keyboardShortcut("2")
            Toggle("Tamanho real", isOn: Binding(get: { view.realSize }, set: { view.realSize = $0 }))
                .keyboardShortcut("0")
            Button("Girar o iPad") { rotate() }
                .keyboardShortcut("r")
                .disabled(ready == nil)
            Divider()
            Button("Página anterior") { step(-1) }
                .keyboardShortcut(.leftArrow)
                .disabled(ready == nil)
            Button("Próxima página") { step(1) }
                .keyboardShortcut(.rightArrow)
                .disabled(ready == nil)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Ajuda do iPDFmini") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
    }

    private func step(_ d: Int) {
        guard let r = ready else { return }
        r.currentPage = max(0, min(r.pageCount - 1, r.currentPage + d))
    }

    private func rotate() {
        guard let r = ready, let id = r.settings.rotatedProfileID else { return }
        r.settings.profileID = id
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: "Adapta PDFs à tela do iPad mini 7: recorte de margens com escala travada, letra fisicamente legível e navegação preservada.\n\n"
                + "Usa qpdf (Apache 2.0), libjpeg-turbo e Swift Argument Parser (Apache 2.0). "
                + "This software is based in part on the work of the Independent JPEG Group. "
                + "Licenças completas em iPDFmini.app/Contents/Resources/Licenses.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

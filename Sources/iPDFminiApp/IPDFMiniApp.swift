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
        // Janela única (§13): a fila mora na lateral, não em janelas por documento.
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

/// Arquivos soltos no ícone do Dock ou "Abrir com" chegam por aqui.
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
            string: "Adapta PDFs à tela do iPad mini 7: recorte de margens com escala travada, letra fisicamente legível e navegação preservada.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

import AppCore
import AppKit
import MiniKit
import Observation
import SwiftUI

/// Estado da folha do lote: configurar → converter → resumo.
@MainActor @Observable
final class BatchSession {
    enum Phase: Equatable {
        case configuring, running, finished(BatchSummary)
        var isFinished: Bool { if case .finished = self { true } else { false } }
    }

    var phase: Phase = .configuring
    let count: Int
    let customized: Int
    private(set) var jobs: [BatchJob] = []
    private(set) var states: [String: BatchJobState] = [:]
    private(set) var destination: URL?
    private(set) var elapsed: TimeInterval?
    private(set) var cancelling = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var forward: (@MainActor (BatchEvent) -> Void)?
    @ObservationIgnored private var completion: (@MainActor (BatchSummary) -> Void)?

    init(count: Int, customized: Int) {
        self.count = count
        self.customized = customized
    }

    var finishedCount: Int { states.values.count(where: \.isFinished) }
    var runningCount: Int { states.values.count { $0 == .running } }

    func start(jobs: [BatchJob], destination: URL, onEvent: @escaping @MainActor (BatchEvent) -> Void,
               completion: @escaping @MainActor (BatchSummary) -> Void) {
        self.jobs = jobs
        self.destination = destination
        states = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, BatchJobState.waiting) })
        forward = onEvent
        self.completion = completion
        started = Date()
        phase = .running
    }

    func run(client: HelperClient, maxConcurrent: Int) async {
        let results = await BatchRunner.run(jobs, client: client, maxConcurrent: maxConcurrent) { [weak self] e in
            self?.handle(e)
        }
        elapsed = Date().timeIntervalSince(started)
        let summary = BatchSummary(results)
        phase = .finished(summary)
        completion?(summary)
    }

    private func handle(_ e: BatchEvent) {
        switch e {
        case .started(let id): states[id] = .running
        case .finished(let id, let o): states[id] = BatchJobState(o)
        }
        forward?(e)
    }

    func cancel() {
        cancelling = true
        task?.cancel()
    }
}

/// AirDrop e alertas (AppKit). Os itens vêm de `ShareItems`, testado no AppCore.
@MainActor
enum Sharing {
    /// `nil` se o AirDrop abriu; senão o motivo, para um alerta claro.
    static func airDrop(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return "Nada para enviar: exporte ou converta um documento primeiro." }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            return "O AirDrop não está disponível neste Mac agora. Ligue o Wi-Fi e o Bluetooth e verifique se o AirDrop está ativo na Central de Controle; ou use Compartilhar na barra de ferramentas."
        }
        service.perform(withItems: urls)
        return nil
    }

    static func alert(_ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Não foi possível enviar por AirDrop"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

struct BatchSheet: View {
    @Environment(Library.self) private var library
    let session: BatchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch session.phase {
            case .configuring: configure
            case .running: progress
            case .finished(let s): summary(s)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 300)
    }

    // MARK: - Configurar

    @ViewBuilder private var configure: some View {
        @Bindable var library = library
        Text("Converter em lote").font(.title2.bold())
        Text(session.count == 1 ? "1 documento selecionado" : "\(session.count) documentos selecionados")
            .foregroundStyle(.secondary)
        Form {
            LabeledContent("Destino") {
                HStack {
                    Text(library.batchDestination?.path(percentEncoded: false) ?? "nenhuma pasta escolhida")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(library.batchDestination == nil ? .secondary : .primary)
                        .help(library.batchDestination?.path(percentEncoded: false) ?? "")
                    Button("Escolher…") { library.chooseBatchDestination() }
                        .accessibilityLabel("Escolher pasta de destino")
                }
            }
            Toggle("Espelhar as subpastas da origem", isOn: $library.mirrorSubfolders)
                .help("Recria dentro do destino as subpastas das pastas arrastadas")
            LabeledContent("Nome") { Text("{título} — mini.pdf · sem sobrescrever (sufixo \" 2\")").foregroundStyle(.secondary) }
            LabeledContent("Ajustes") {
                Text(session.customized == 0 ? "padrão do lote em todos"
                     : "padrão do lote; \(session.customized) com ajustes próprios")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        HStack {
            Spacer()
            Button("Cancelar", role: .cancel) { library.closeBatch() }
                .keyboardShortcut(.cancelAction)
            Button("Converter \(session.count)") { library.startBatch() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(library.batchDestination == nil)
        }
    }

    // MARK: - Progresso

    @ViewBuilder private var progress: some View {
        Text(session.cancelling ? "Cancelando…" : "Convertendo…").font(.title2.bold())
        ProgressView(value: Double(session.finishedCount), total: Double(max(1, session.jobs.count))) {
            Text("\(session.finishedCount) de \(session.jobs.count) concluídos · \(session.runningCount) em andamento")
                .monospacedDigit()
        }
        .accessibilityLabel("Progresso do lote")
        .accessibilityValue("\(session.finishedCount) de \(session.jobs.count)")
        List(session.jobs) { job in
            HStack(spacing: 8) {
                stateIcon(session.states[job.id] ?? .waiting)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.displayName).lineLimit(1)
                    Text(job.output.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text((session.states[job.id] ?? .waiting).title).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(minHeight: 220)
        HStack {
            Spacer()
            Button("Cancelar lote", role: .destructive) { session.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.cancelling)
                .help("Interrompe os processos em andamento; os já convertidos ficam")
        }
    }

    @ViewBuilder private func stateIcon(_ s: BatchJobState) -> some View {
        switch s {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Aguardando")
        case .running: ProgressView().controlSize(.small)
        case .converted(let ok):
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Resumo

    @ViewBuilder private func summary(_ s: BatchSummary) -> some View {
        Text("Lote concluído").font(.title2.bold())
        Text(s.headline + (session.elapsed.map { " · \(Describe.number($0)) s" } ?? ""))
            .foregroundStyle(.secondary)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Falhas", "xmark.octagon.fill", .red, s.failures)
                section("Invariantes reprovados", "xmark.seal.fill", .red, s.failedInvariants)
                section("Avisos de legibilidade", "textformat.size.smaller", .orange, s.legibilityWarnings)
                section("Sumário incompleto", "list.bullet.indent", .orange, s.outlineProblems)
                if s.failures.isEmpty && s.failedInvariants.isEmpty && s.legibilityWarnings.isEmpty
                    && s.outlineProblems.isEmpty && s.convertedCount > 0 {
                    Label("Todos convertidos e validados, sem avisos; sumários preservados.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 160, maxHeight: 360)
        HStack {
            Button("Mostrar no Finder") {
                let urls = s.shareItems
                if urls.isEmpty, let d = session.destination { NSWorkspace.shared.open(d) } else {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            .disabled(s.shareItems.isEmpty && session.destination == nil)
            Button("Enviar por AirDrop…") { library.airDrop(s.shareItems) }
                .disabled(s.shareItems.isEmpty)
                .help("Envia os \(s.shareItems.count) PDFs convertidos de uma vez")
            Spacer()
            Button("Fechar") { library.closeBatch() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func section(_ title: String, _ symbol: String, _ color: Color, _ lines: [BatchSummary.Line]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(title) (\(lines.count))", systemImage: symbol).font(.headline).foregroundStyle(color)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.name).font(.callout.weight(.medium))
                        Text(l.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

import AppCore
import LayoutEngine
import MiniGeometry
import MiniKit
import SwiftUI

struct InspectorView: View {
    @Environment(Library.self) private var library
    @Bindable var item: DocumentItem

    /// Toda edição passa pela `Library`: vira ajuste próprio deste documento.
    private var settings: Binding<ConversionSettings> {
        Binding(get: { item.settings }, set: { library.update(item, $0) })
    }

    /// Desligar a divisão também tira um modo de fatias que tenha ficado escolhido.
    private var allowSplitting: Binding<Bool> {
        Binding(get: { item.settings.allowSplitting }, set: { on in
            var s = item.settings
            s.setAllowSplitting(on)
            library.update(item, s)
        })
    }

    var body: some View {
        Form {
            scopeSection
            profileSection
            strategySection
            cropSection
            legibilitySection
            warningsSection
            documentSection
            exportSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Padrão do lote × ajustes próprios

    private var scopeSection: some View {
        Section {
            if library.hasOwnSettings(item) {
                Label("Ajustes próprios deste documento", systemImage: "slider.horizontal.3")
                HStack {
                    Button("Tornar padrão") { library.useAsDefault(item) }
                        .help("Os documentos sem ajustes próprios passam a usar estes ajustes")
                    Button("Voltar ao padrão") { library.resetToDefault(item) }
                }
                .buttonStyle(.glass)
            } else {
                Label("Segue o padrão do lote", systemImage: "square.stack.3d.down.right")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Mudar um ajuste aqui vale só para este documento; no lote, os demais usam o padrão.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Perfil

    private var profileSection: some View {
        Section("Perfil") {
            Picker("Leitor e orientação", selection: settings.profileID) {
                ForEach(ViewportProfile.builtIn) { p in
                    Text(Labels.profile(p)).tag(p.id)
                }
            }
            let p = item.settings.profile
            LabeledContent("Área útil") {
                Text("\(Describe.size(p.sizePt)) · \(Describe.number(Double(Units.ptToMM(p.sizePt.width)))) × \(Describe.number(Double(Units.ptToMM(p.sizePt.height)))) mm")
                    .multilineTextAlignment(.trailing)
            }
            .font(.callout)
        }
    }

    // MARK: - Estratégia

    private var strategySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(Labels.allowSplittingTitle, isOn: allowSplitting)
                Text(Labels.allowSplittingFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Modo", selection: settings.mode) {
                ForEach(Labels.modes(allowSplitting: item.settings.allowSplitting), id: \.self) { m in
                    Text(Labels.mode(m)).tag(m)
                }
            }
            if let r = item.planned {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Candidatos").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(r.candidates.enumerated()), id: \.offset) { i, c in
                        candidateRow(c, chosen: i == r.chosenIndex)
                    }
                }
            }
            if let e = item.planError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Estratégia")
        } footer: {
            Text("Automático escolhe o candidato de menor custo de fidelidade que atinge o alvo de legibilidade. Clique num candidato para forçá-lo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ c: CandidateSummary, chosen: Bool) -> some View {
        Button {
            if let s = item.settings.forcing(c) { library.update(item, s) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                Text(Labels.candidate(c))
                    .fontWeight(chosen ? .semibold : .regular)
                Spacer(minLength: 4)
                Circle().fill(tierColor(c.tier)).frame(width: 8, height: 8)
                    .help(Labels.tier(c.tier))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.settings.forcing(c) == nil)
        .accessibilityLabel("\(Labels.candidate(c)), \(Labels.tier(c.tier))\(chosen ? ", escolhido" : "")")
    }

    private func tierColor(_ t: String) -> Color {
        switch t {
        case "meetsTarget": .green
        case "meetsMinimum": .yellow
        default: .red
        }
    }

    // MARK: - Recorte

    private var cropSection: some View {
        Section("Recorte") {
            VStack(alignment: .leading) {
                LabeledContent("Respiro") {
                    Text("\(Describe.number(item.settings.marginMM)) mm").monospacedDigit()
                }
                Slider(value: settings.marginMM, in: 0...10, step: 0.5) {
                    Text("Respiro")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("10")
                }
                .labelsHidden()
                .accessibilityValue("\(Describe.number(item.settings.marginMM)) milímetros")
            }
            Picker("Classes de escala", selection: settings.classMode) {
                ForEach(Labels.classModes, id: \.self) { c in
                    Text(Labels.classMode(c)).tag(c)
                }
            }
        }
    }

    // MARK: - Legibilidade

    @ViewBuilder private var legibilitySection: some View {
        if let r = item.planned {
            let c = r.chosen
            let leg = r.plan.recipe.legibility
            Section("Legibilidade do corpo") {
                if let pt = c.bodyPointSizeEquivalent, let mm = c.bodyXHeightMM {
                    LabeledContent("No mini") {
                        Text("\(Describe.number(pt)) pt · altura-x \(Describe.number(mm, decimals: 2)) mm")
                            .monospacedDigit()
                    }
                    Gauge(value: min(max(mm, 0.5), 2.5), in: 0.5...2.5) {
                        Text("Altura-x")
                    } currentValueLabel: {
                        Text(Labels.tier(c.tier))
                    } minimumValueLabel: {
                        Text("0,5 mm").font(.caption2)
                    } maximumValueLabel: {
                        Text("2,5 mm").font(.caption2)
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(Gradient(colors: [.red, .yellow, .green, .green, .blue]))
                    .accessibilityLabel("Altura-x no mini: \(Describe.number(mm, decimals: 2)) milímetros, \(Labels.tier(c.tier))")
                    Text("Mínimo \(Describe.number(leg.minimumMM, decimals: 2)) mm · alvo \(Describe.number(leg.targetMM, decimals: 2)) mm (\(Describe.number(Legibility.pointSizeEquivalent(xHeightMM: leg.targetMM))) pt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Altura-x do corpo não medida (sem texto extraível).")
                        .foregroundStyle(.secondary)
                }
                if let o = AnalysisSummary(r.analysis).bodyPointSizeEquivalent {
                    LabeledContent("Na origem") { Text("\(Describe.number(o)) pt equivalente").monospacedDigit() }
                }
                if let ms = item.replanMillis {
                    LabeledContent("Replanejado em") { Text("\(Describe.number(ms, decimals: ms < 1 ? 2 : 1)) ms").monospacedDigit() }
                        .font(.caption)
                        .foregroundStyle(ms <= 100 ? Color.secondary : Color.orange)
                }
            }
        }
    }

    // MARK: - Avisos

    private var warningsSection: some View {
        Section("Avisos") {
            let w = item.allWarnings
            if w.isEmpty {
                Label("Nenhum aviso", systemImage: "checkmark.seal").foregroundStyle(.green)
            } else {
                ForEach(Array(w.enumerated()), id: \.offset) { _, s in
                    Label(s, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Documento

    @ViewBuilder private var documentSection: some View {
        if let r = item.planned {
            let a = AnalysisSummary(r.analysis)
            Section("Documento") {
                LabeledContent("Tipo", value: Describe.documentKind(a.kind))
                LabeledContent("Páginas") { Text("\(a.pageCount) → \(r.plan.pages.count) de saída").monospacedDigit() }
                LabeledContent("Tamanhos") {
                    Text(a.sizeGroups.map { "\(Describe.size($0.size)) (\($0.pages))" }.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                }
                if let o = OutlineDisplay.source(item.sourceOutlineItems) {
                    LabeledContent("Navegação") {
                        Label(o, systemImage: "list.bullet.indent")
                            .foregroundStyle(item.sourceOutlineItems == 0 ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Exportação

    private var exportSection: some View {
        Section("Exportação") {
            Button {
                library.export(item)
            } label: {
                if item.status == .converting {
                    HStack { ProgressView().controlSize(.small); Text("Exportando e validando…") }
                } else {
                    Label("Exportar…", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(item.status == .converting)
            if let e = item.exportError {
                Label(e, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }
            if let r = item.lastExport {
                let passed = r.passed
                Label(passed ? "Validação aprovada" : "Validação reprovada",
                      systemImage: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(passed ? .green : .red)
                if let v = r.validation {
                    ForEach(v.results, id: \.id) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: icon(i.status)).foregroundStyle(color(i.status))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(i.id) · \(i.title)").font(.callout)
                                Text(i.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Invariante \(i.id), \(i.title): \(Labels.invariantStatus(i.status)). \(i.detail)")
                    }
                }
                if let n = OutlineDisplay.counts(r) {
                    if n.sourceOutlineItems == 0 {
                        Label("Sumário: sem sumário na origem", systemImage: "list.bullet.indent")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Sumário: \(OutlineDisplay.preserved(n))",
                              systemImage: n.outlinePreserved ? "list.bullet.indent" : "exclamationmark.triangle")
                            .foregroundStyle(n.outlinePreserved ? Color.green : Color.orange)
                            .accessibilityLabel("Sumário na saída: \(OutlineDisplay.preserved(n))")
                    }
                }
                if let url = item.lastExportURL {
                    HStack {
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Enviar por AirDrop…") { library.airDrop([url]) }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func icon(_ s: InvariantStatus) -> String {
        switch s {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .notApplicable: "minus.circle"
        }
    }

    private func color(_ s: InvariantStatus) -> Color {
        switch s {
        case .passed: .green
        case .failed: .red
        case .notApplicable: .secondary
        }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("Ajuda do iPDFmini").font(.title.bold())
                }
                helpItem("Abrir", "Arraste PDFs ou pastas para a janela ou para o ícone no Dock, ou use Arquivo › Abrir… (⌘O). Pastas entram com todos os PDFs das subpastas; arrastar mais soma à fila sem repetir. Cada PDF é analisado num processo separado (dois por vez): um arquivo corrompido vira “Falha” na fila e o app continua aberto.")
                helpItem("Lote", "A lateral agrupa a fila por pasta. Desmarque a caixa dos documentos que não quer converter; o menu de cada pasta marca ou desmarca todos dela, e Seleção › Remover desmarcados limpa a fila. Converter selecionados (⇧⌘B) pede a pasta de destino, pode espelhar as subpastas e termina com um resumo de falhas, avisos e invariantes.")
                helpItem("AirDrop", "Exportar e enviar por AirDrop (⇧⌘E) exporta o documento e abre o AirDrop. O resumo do lote envia todos os PDFs convertidos de uma vez. Compartilhar, na barra, oferece os demais serviços do macOS.")
                helpItem("Origem e Mini", "Origem (⌘1) mostra a página original com a janela de recorte em laranja e as áreas removidas hachuradas. Mini (⌘2) mostra a página exportada dentro da moldura do iPad mini 7. Use as setas ← → (ou ⌘← ⌘→) para virar as páginas.")
                helpItem("Tamanho real", "Com “Tamanho real” (⌘0) a tela do iPad mini é desenhada com 115,94 × 176,55 mm, a partir das dimensões físicas que o monitor informa. Segure o iPad ao lado para comparar.")
                helpItem("Ajustes", "No inspetor: perfil do leitor, modo (Automático, Recorte, Recorte sem cabeçalho/rodapé, Passagem direta), respiro em mm e classes de escala. Por padrão cada página do original vira exatamente uma tela; “Permitir dividir páginas” libera Paisagem, Fatias em retrato e Colunas, que podem espalhar uma página por várias telas. A tabela de candidatos mostra o corpo do texto em pt equivalente e quantas telas cada página de origem ocupa.")
                helpItem("Exportar", "Exportar… (⌘E) grava “{título} — mini.pdf” e valida a saída: nenhuma tinta cortada, proporção do viewport, legibilidade, navegação e cantos. O inspetor mostra quantos itens do sumário a origem tem e quantos chegaram à saída apontando para a página certa.")
                helpItem("Calibração", "Arquivo › Gerar PDF de calibração… cria uma página com réguas nas bordas. Abra no leitor do iPad mini e anote a primeira marca visível em cada borda para medir a área útil real.")
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func helpItem(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

import Foundation
import AppKit
import WebKit
import PDFKit
import CoreGraphics

// S7 — WebKit pagina EPUB/HTML na página do mini com hifenização?
// Roda no main actor com o RunLoop principal girando; sem app bundle.

// MARK: - Modelo do capítulo

struct S7Block {
    enum Kind { case toc, h1, h2, p, note }
    var kind: Kind
    var lang: String
    var text: String      // texto visível (o que o PDF deve conter)
    var html: String      // marcação XHTML do bloco
    var target: String?   // id de destino (toc → h2)
    var dialogue = false
}

struct S7Rng {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

/// Gerador determinístico de um capítulo pt-BR com diálogos.
struct S7Chapter {
    struct Noun { let w: String; let f: Bool }
    struct Adj { let m: String; let f: String }
    struct NP {
        let n: Noun; let adj: String?
        var rest: String { adj.map { n.w + " " + $0 } ?? n.w }
        var text: String { (n.f ? "a " : "o ") + rest }
        var de: String { (n.f ? "da " : "do ") + rest }
        var em: String { (n.f ? "na " : "no ") + rest }
        var indef: String { (n.f ? "uma " : "um ") + rest }
    }

    static let nouns: [Noun] = ([
        "relojoeiro", "capitão", "bibliotecário", "carteiro", "farmacêutico", "engenheiro", "pescador", "cartógrafo",
        "telegrafista", "professor", "contador", "marceneiro", "astrônomo", "vizinho", "sacristão", "tipógrafo",
        "arquiteto", "armazém", "telhado", "candeeiro", "relógio", "barômetro", "manuscrito", "lampião", "mercado",
        "pátio", "porão", "sobrado", "caminho", "inverno", "silêncio", "paralelepípedo", "guarda-chuva", "telescópio",
        "laboratório", "anfiteatro", "cemitério", "monumento", "vendaval", "mapa", "diário", "baú",
    ].map { Noun(w: $0, f: false) }) + ([
        "biblioteca", "carta", "estação", "janela", "escada", "fotografia", "lembrança", "cidade", "paisagem",
        "tempestade", "responsabilidade", "oficina", "cartografia", "livraria", "chaminé", "vitrine", "ladeira",
        "varanda", "tipografia", "encomenda", "ferrovia", "madrugada", "neblina", "pensão", "praça", "fábrica",
        "maquinaria", "explicação", "desconfiança", "impressão", "expectativa", "conversa", "viagem", "coleção",
        "enciclopédia", "correspondência", "irmandade", "incerteza", "lanterna", "maleta", "partitura", "bússola",
        "ponte", "torre",
    ].map { Noun(w: $0, f: true) })

    static let adjs: [Adj] = [
        Adj(m: "antigo", f: "antiga"), Adj(m: "silencioso", f: "silenciosa"),
        Adj(m: "extraordinário", f: "extraordinária"), Adj(m: "incompreensível", f: "incompreensível"),
        Adj(m: "empoeirado", f: "empoeirada"), Adj(m: "distante", f: "distante"), Adj(m: "minucioso", f: "minuciosa"),
        Adj(m: "improvável", f: "improvável"), Adj(m: "inesperado", f: "inesperada"),
        Adj(m: "indispensável", f: "indispensável"), Adj(m: "desconfiado", f: "desconfiada"),
        Adj(m: "interminável", f: "interminável"), Adj(m: "meticuloso", f: "meticulosa"),
        Adj(m: "abandonado", f: "abandonada"), Adj(m: "irregular", f: "irregular"), Adj(m: "imponente", f: "imponente"),
        Adj(m: "constante", f: "constante"), Adj(m: "sorrateiro", f: "sorrateira"),
        Adj(m: "transparente", f: "transparente"), Adj(m: "paciente", f: "paciente"),
        Adj(m: "enferrujado", f: "enferrujada"), Adj(m: "desmantelado", f: "desmantelada"),
        Adj(m: "misterioso", f: "misteriosa"), Adj(m: "fundamental", f: "fundamental"),
        Adj(m: "insuportável", f: "insuportável"),
    ]
    static let names = ["Aurélio", "Helena", "Teodoro", "Clarice", "Otávio", "Mariana", "Joaquim", "Beatriz", "Raimundo", "Lúcia"]
    static let verbs: [(past: String, inf: String)] = [
        ("examinou", "examinar"), ("abandonou", "abandonar"), ("procurou", "procurar"), ("esqueceu", "esquecer"),
        ("reconheceu", "reconhecer"), ("atravessou", "atravessar"), ("guardou", "guardar"), ("observou", "observar"),
        ("consertou", "consertar"), ("imaginou", "imaginar"), ("descreveu", "descrever"), ("protegeu", "proteger"),
        ("lembrou", "lembrar"), ("evitou", "evitar"), ("mencionou", "mencionar"), ("carregou", "carregar"),
        ("desenhou", "desenhar"), ("interrompeu", "interromper"),
    ]

    static let enParagraph = "The old watchmaker had always insisted that extraordinary craftsmanship requires uncompromising patience. In his workshop, every mechanism was disassembled, catalogued, and reassembled with an almost religious thoroughness, because misunderstanding even a single component could compromise the entire instrument. His apprentices, who frequently complained about the unreasonable standards, eventually understood that responsibility was not an inconvenience but the foundation of their profession. Nobody remembered when the neighbourhood stopped questioning his unconventional methods; the community simply acknowledged that irreplaceable knowledge deserves extraordinary protection, and that technological progress, however impressive, could never substitute the meticulous understanding passed down from generation to generation. Whenever a stranger asked about the secret of the workshop, the answer was invariably the same: nothing is accomplished without determination, and nothing endures without maintenance."

    static let footnote = "Os relógios de torre dessa época costumavam adiantar-se até quatro minutos por semana, e cabia ao relojoeiro municipal acertá-los aos domingos, depois da missa, com a paciência de quem corrige um erro que sabe inevitável."

    static let sectionTitles = [
        "O relógio da estação", "A carta sem remetente", "Uma noite de neblina",
        "O mapa incompleto", "A oficina do tipógrafo", "O regresso pela ladeira",
    ]
    static let chapterTitle = "Capítulo 3 — A cidade dos relojoeiros"

    var rng = S7Rng(s: 20_261_110)
    var blocks: [S7Block] = []

    mutating func np(adj: Bool = true) -> NP {
        let n = rng.pick(Self.nouns)
        let a: String? = (adj || rng.int(10) < 6) ? { let x = rng.pick(Self.adjs); return n.f ? x.f : x.m }() : nil
        return NP(n: n, adj: rng.int(10) < 7 ? a : nil)
    }
    mutating func pp() -> String {
        switch rng.int(5) {
        case 0: return "em " + np().text.dropFirstWord(as: "em")
        case 1: return "perto " + np().de
        case 2: return "diante " + np().de
        case 3: return "atrás " + np().de
        default: return "durante " + np().text
        }
    }
    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Sentença sem ponto final.
    mutating func sentence() -> String {
        let v = rng.pick(Self.verbs), v2 = rng.pick(Self.verbs)
        let name = rng.pick(Self.names)
        switch rng.int(9) {
        case 0: return Self.cap("\(np().text) \(v.past) \(np().text) \(pp())")
        case 1: return "Depois de \(v.inf) \(np().text), \(name) \(v2.past) \(np().text)"
        case 2: return "Ninguém \(v.past) \(np().text) sem \(v2.inf) \(np().text) antes"
        case 3: return "\(name) sabia que \(np().text) \(v.past) \(np().text), e isso já era suficiente"
        case 4:
            let n1 = np(), a2 = rng.pick(Self.adjs)
            return "Era \(n1.indef), muito mais \(n1.n.f ? a2.f : a2.m) do que \(np().text)"
        case 5: return "Quando \(np().text) \(v.past) \(np().text), \(name) percebeu que tudo estava diferente"
        case 6: return "Ao amanhecer, \(np().text) \(v.past) \(np().text) e voltou para \(np().text)"
        case 7: return "Havia \(np().indef) \(pp()), e ninguém sabia explicar por quê"
        default: return "\(name) \(v.past) \(np().text), mas não conseguiu \(v2.inf) \(np().text)"
        }
    }

    mutating func narration(sentences: Int) -> [String] { (0..<sentences).map { _ in sentence() + "." } }

    mutating func exchange(lines: Int) -> [String] {
        var out: [String] = []
        var a = rng.pick(Self.names), b = rng.pick(Self.names)
        while b == a { b = rng.pick(Self.names) }
        for i in 0..<lines {
            let (who, other) = i % 2 == 0 ? (a, b) : (b, a)
            _ = other
            switch rng.int(5) {
            case 0: out.append("— Você já viu \(np().indef)? — perguntou \(who).")
            case 1:
                let v = rng.pick(Self.verbs)
                out.append("— Onde \(rng.pick(Self.names)) \(v.past) \(np().text)? — quis saber \(who).")
            case 2: out.append("— \(sentence()), respondeu \(who).")
            case 3: out.append("— Talvez \(np().text) \(rng.pick(Self.verbs).past) \(np().text), disse \(who).")
            default: out.append("— \(sentence()), murmurou \(who).")
            }
        }
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Monta o capítulo (~6 000 palavras no corpo).
    mutating func build(targetWordsPerSection: Int = 985) {
        blocks = []
        // Sumário (nav) — preenchido depois, precisa dos ids
        var body: [S7Block] = []
        body.append(S7Block(kind: .h1, lang: "pt-BR", text: Self.chapterTitle, html: "<h1 id=\"top\">\(Self.esc(Self.chapterTitle))</h1>", target: nil))
        for (si, title) in Self.sectionTitles.enumerated() {
            let id = "s\(si + 1)"
            body.append(S7Block(kind: .h2, lang: "pt-BR", text: title, html: "<h2 id=\"\(id)\">\(Self.esc(title))</h2>", target: id))
            var words = 0, paraIdx = 0
            while words < targetWordsPerSection {
                var sents = narration(sentences: 5 + rng.int(4))
                var html: String, text: String
                if si == 1 && paraIdx == 1 {
                    // nota de rodapé: marcador após a 2ª sentença
                    let head = sents[0...1].joined(separator: " "), tail = sents[2...].joined(separator: " ")
                    html = "\(Self.esc(head))<a class=\"noteref\" epub:type=\"noteref\" id=\"fnref1\" href=\"#fn1\"><sup>1</sup></a> \(Self.esc(tail))"
                    text = head + "1 " + tail
                } else {
                    html = Self.esc(sents.joined(separator: " ")); text = sents.joined(separator: " ")
                }
                sents = []
                body.append(S7Block(kind: .p, lang: "pt-BR", text: text, html: "<p\(paraIdx == 0 ? " class=\"first\"" : "")>\(html)</p>", target: nil))
                words += text.split(separator: " ").count
                if paraIdx % 2 == 1 {
                    for l in exchange(lines: 4 + rng.int(4)) {
                        body.append(S7Block(kind: .p, lang: "pt-BR", text: l, html: "<p class=\"dlg\">\(Self.esc(l))</p>", target: nil, dialogue: true))
                        words += l.split(separator: " ").count
                    }
                }
                if si == 3 && paraIdx == 1 {
                    body.append(S7Block(kind: .p, lang: "en", text: Self.enParagraph, html: "<p lang=\"en\">\(Self.esc(Self.enParagraph))</p>", target: nil))
                    words += Self.enParagraph.split(separator: " ").count
                }
                paraIdx += 1
            }
        }
        // Sumário primeiro
        blocks.append(S7Block(kind: .toc, lang: "pt-BR", text: "Sumário", html: "<p class=\"toc-title\">Sumário</p>", target: nil))
        for (si, title) in Self.sectionTitles.enumerated() {
            blocks.append(S7Block(kind: .toc, lang: "pt-BR", text: title, html: "<li><a href=\"#s\(si + 1)\">\(Self.esc(title))</a></li>", target: "s\(si + 1)"))
        }
        blocks += body
        let fn = "1. " + Self.footnote
        blocks.append(S7Block(kind: .note, lang: "pt-BR", text: fn,
                              html: "<aside epub:type=\"footnote\" id=\"fn1\"><p><a href=\"#fnref1\">1</a>. \(Self.esc(Self.footnote))</p></aside>", target: nil))
    }

    var bodyWordCount: Int {
        blocks.filter { $0.kind == .p || $0.kind == .h1 || $0.kind == .h2 }.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    /// XHTML do capítulo. `pageMarginCSS` = false: @page sem margem (margens ficam com o NSPrintInfo).
    struct CSSOptions {
        var pageMargin = true          // margens no @page (senão @page margin: 0)
        var hyphens = true
        var legacyBreaks = false       // page-break-after: avoid + break-after: avoid-page nos títulos
        var limitChars = false         // hyphenate-limit-chars: 7 3 3
        var limitLines = false         // -webkit-hyphenate-limit-lines: 2
        var keepWrap = false           // h2 + 1º parágrafo num div com break-inside: avoid
        var widowsOrphans = 2
        var font = "Charter, \"Iowan Old Style\", serif"
    }

    func xhtml(_ o: CSSOptions) -> String {
        let margin = o.pageMargin ? "14pt 16pt 18pt 16pt" : "0"
        let hyphens = o.hyphens
        let wo = o.widowsOrphans
        let headBreak = o.legacyBreaks ? "page-break-after: avoid; break-after: avoid-page;" : "break-after: avoid;"
        let limit = (o.limitChars ? "hyphenate-limit-chars: 7 3 3; -webkit-hyphenate-limit-before: 3; -webkit-hyphenate-limit-after: 3;" : "")
            + (o.limitLines ? " -webkit-hyphenate-limit-lines: 2; hyphenate-limit-lines: 2;" : "")
        let css = """
        @page { size: 328.64pt 500.47pt; margin: \(margin); }
        html { hyphens: \(hyphens ? "auto" : "manual"); -webkit-hyphens: \(hyphens ? "auto" : "manual"); \(limit) }
        body { margin: 0; font-family: \(o.font); font-size: 10.5pt; line-height: 1.4;
               widows: \(wo); orphans: \(wo); text-align: left; }
        p { margin: 0; text-indent: 1.2em; widows: \(wo); orphans: \(wo); }
        p.first, p.dlg, h1 + p, h2 + p { text-indent: 0; }
        h1 { font-size: 17pt; line-height: 1.2; margin: 0 0 14pt; \(headBreak) }
        h2 { font-size: 13pt; line-height: 1.25; margin: 16pt 0 8pt; \(headBreak) }
        nav { break-after: page; }
        .keep { break-inside: avoid; page-break-inside: avoid; }
        nav ol { list-style: none; margin: 8pt 0 0; padding: 0; }
        nav li { margin: 0 0 4pt; }
        .toc-title { font-size: 13pt; font-weight: bold; text-indent: 0; }
        a { color: inherit; text-decoration: none; }
        aside { margin-top: 14pt; font-size: 9pt; line-height: 1.35; border-top: 0.5pt solid #888; padding-top: 4pt; }
        aside p { text-indent: 0; }
        """
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        out += "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"pt-BR\" xml:lang=\"pt-BR\">\n"
        out += "<head><meta charset=\"utf-8\"/><title>\(Self.esc(Self.chapterTitle))</title><style>\n\(css)\n</style></head>\n<body>\n"
        out += "<nav epub:type=\"toc\" id=\"toc\">\n"
        let toc = blocks.filter { $0.kind == .toc }
        out += toc[0].html + "\n<ol>\n" + toc.dropFirst().map { $0.html }.joined(separator: "\n") + "\n</ol>\n</nav>\n"
        var wrapOpen = false
        for b in blocks where b.kind != .toc {
            if o.keepWrap, b.kind == .h2 { out += "<div class=\"keep\">\n"; wrapOpen = true }
            out += b.html + "\n"
            if wrapOpen, b.kind == .p { out += "</div>\n"; wrapOpen = false }
        }
        out += "</body>\n</html>\n"
        return out
    }
}

private extension String {
    /// "a ponte" → "ponte" quando o artigo já está contraído em "em".
    func dropFirstWord(as _: String) -> String {
        let art = hasPrefix("a ") ? "na " : "no "
        return art + dropFirst(2)
    }
}

// MARK: - Delegates

@MainActor final class S7Nav: NSObject, WKNavigationDelegate {
    var done = false
    var error: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError e: Error) { error = "\(e)"; done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError e: Error) {
        error = "\(e)"; done = true
    }
}

// O AppKit chama o delegate numa thread de paginação, fora do main actor.
final class S7PrintDone: NSObject, @unchecked Sendable {
    nonisolated(unsafe) var finished = false
    nonisolated(unsafe) var success = false
    @objc nonisolated func didRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finished = true
        self.success = success
    }
}

final class S7Box<T>: @unchecked Sendable { var value: T?; init() {} }

// MARK: - Métricas

struct S7Line {
    var text: String
    var page: Int
    var rect: CGRect      // espaço da página, origem no canto da MediaBox
    var block: Int = -1
    var indexInBlock = 0
    var linesInBlock = 0
}

struct S7Stat {
    var n = 0, mean = 0.0, sd = 0.0, min = 0.0, max = 0.0
    init(_ v: [Double]) {
        n = v.count
        guard n > 0 else { return }
        mean = v.reduce(0, +) / Double(n)
        sd = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot()
        min = v.min()!; max = v.max()!
    }
    var text: String { n == 0 ? "n/d" : "\(fmt(mean, 1)) ± \(fmt(sd, 1)) (\(fmt(min, 0))–\(fmt(max, 0)), n=\(n))" }
}

struct S7Metrics {
    var ok = false
    var pages = 0
    var sizes: [String: Int] = [:]
    var sizeOK = 0
    var fileBytes = 0
    var seconds = 0.0
    var letters = 0, sourceLetters = 0
    var aligned = false
    var alignNote = ""
    var lineCount = 0
    var cplInterior = S7Stat([])
    var cplNonFinal = S7Stat([])
    var cplAll = S7Stat([])
    var extent = ""
    var hyphen: [String: (total: Int, valid: Int)] = [:]
    var hyphenSamples: [String] = []
    var hyphenBad: [String] = []
    var widows: [String] = [], orphans: [String] = []
    var headingsAtFoot: [String] = []
    var fillMean = 0.0, fillMedian = 0.0, fillMin = 0.0
    var inRangePct = 0.0                    // % das linhas internas com 55–65 caracteres
    var naturalHyphens = 0                  // hífen próprio da palavra (guarda-chuva) no fim da linha
    var maxHyphenRun = 0                    // maior sequência de linhas consecutivas terminadas em hífen
    var shortFrag = 0                       // quebras com fragmento < 3 letras
    var splitParas = 0
    var splitPatterns: [String: Int] = [:]
    var linksTotal = 0, linksGoTo = 0, linksURI = 0
    var tocOK = 0, tocTotal = 0
    var noteRefOK = false, noteBackOK = false
    var outline = 0
    var fonts: [String] = []
    var shortPages: [Int] = []
}

// MARK: - Spike

@MainActor
enum S7 {
    static let pageW: CGFloat = 328.64
    static let pageH: CGFloat = 500.47
    static let hyphenChars: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{00AD}"]

    struct PathResult {
        var id: String
        var title: String
        var note: String
        var pdf: URL?
        var generateSeconds: Double
        var loadSeconds: Double
        var m: S7Metrics?
    }

    static func main(out: URL) -> Never {
        if ProcessInfo.processInfo.environment["S7_SYNC_PROBE"] != nil { probeSync(dir: out.deletingLastPathComponent()) }
        do {
            let dir = out.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let t0 = now()
            let r = try run(dir: dir)
            var head = Markdown()
            head.heading(1, "Resultados do spike S7 — paginação no WebKit")
            head.para("Gerado por `ipdfmini-spikes s7`. Página alvo \(pageW) × \(pageH) pt. macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Tempo total \(fmt(now() - t0, 1)) s.")
            try (head.text + "\n" + r.markdown).write(to: out, atomically: true, encoding: .utf8)
            print(r.summary.joined(separator: "\n"))
            print("markdown: \(out.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("s7: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Sonda `NSPrintOperation.run()` síncrono no WKWebView (pode travar; rodar com alarme externo).
    static func probeSync(dir: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (web, win, _, ok, err) = makeView(url: dir.appendingPathComponent("s7-chapter-A.xhtml"), dir: dir)
        _ = win
        guard ok else { print("sync-probe: navegação falhou \(err)"); exit(1) }
        let out = dir.appendingPathComponent("s7-sync-probe.pdf")
        try? FileManager.default.removeItem(at: out)
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = NSSize(width: pageW, height: pageH)
        info.topMargin = 0; info.leftMargin = 0; info.bottomMargin = 0; info.rightMargin = 0
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out as NSURL
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false; op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: pageW, height: pageH)
        fputs("sync-probe: chamando run()\n", stderr)
        let t0 = now()
        let r = op.run()
        fputs("sync-probe: run() retornou \(r) em \(fmt(now() - t0, 2)) s; arquivo \(fileSize(out)) bytes\n", stderr)
        exit(0)
    }

    // Gira o RunLoop até a condição ou o tempo-limite.
    static func spin(_ timeout: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    static func run(dir: URL) throws -> SpikeResult {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var ch = S7Chapter()
        ch.build()
        func write(_ name: String, _ o: S7Chapter.CSSOptions) throws -> URL {
            let u = dir.appendingPathComponent("s7-chapter-\(name).xhtml")
            try ch.xhtml(o).write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let base = S7Chapter.CSSOptions()
        let urlA = try write("A", base)                                   // @page com margens
        var oB = base; oB.pageMargin = false
        let urlB = try write("B", oB)                                     // @page sem margem
        var oNH = base; oNH.hyphens = false
        let urlNH = try write("nohyph", oNH)                              // controle sem hifenização
        var oLeg = base; oLeg.legacyBreaks = true
        let urlLeg = try write("legacybreaks", oLeg)
        var oLim = base; oLim.limitChars = true
        let urlLim = try write("limitchars", oLim)
        var oWO = base; oWO.widowsOrphans = 1
        let urlWO = try write("wo1", oWO)
        var oIowan = base; oIowan.font = "\"Iowan Old Style\", serif"
        let urlIowan = try write("iowan", oIowan)
        var oNY = base; oNY.font = "ui-serif, \"New York\", serif"
        let urlNY = try write("newyork", oNY)

        var results: [PathResult] = []
        let z: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)

        // 1. createPDF
        results.append(pathCreatePDF(dir: dir, chapter: ch, url: urlA))
        // 2a. printOperation, margens do NSPrintInfo zero, margens no @page
        results.append(pathPrint(dir: dir, chapter: ch, url: urlA, id: "2a", name: "printOperation(with:) — runModal, margens NSPrintInfo = 0, @page com margens",
                                 file: "s7-path2a-print-margin0.pdf", margins: z, view: false))
        // 2b. margens no NSPrintInfo, @page sem margem
        results.append(pathPrint(dir: dir, chapter: ch, url: urlB, id: "2b", name: "printOperation(with:) — runModal, margens no NSPrintInfo (14/16/18/16), @page margin 0",
                                 file: "s7-path2b-print-infomargins.pdf", margins: (14, 16, 18, 16), view: false))
        // 2c. controle sem hifenização
        results.append(pathPrint(dir: dir, chapter: ch, url: urlNH, id: "2c", name: "controle: igual a 2a com `hyphens: manual`",
                                 file: "s7-path2c-print-nohyph.pdf", margins: z, view: false))
        // 2d. paperSize diferente do @page size: quem manda?
        results.append(pathPrint(dir: dir, chapter: ch, url: urlA, id: "2d", name: "igual a 2a, mas NSPrintInfo.paperSize = 400 × 600 (o `@page size` continua 328,64 × 500,47)",
                                 file: "s7-path2d-papersize-conflict.pdf", margins: z, view: false, paper: NSSize(width: 400, height: 600)))
        // 2e. quebras legadas nos títulos
        results.append(pathPrint(dir: dir, chapter: ch, url: urlLeg, id: "2e", name: "igual a 2a com `page-break-after: avoid; break-after: avoid-page` nos títulos",
                                 file: "s7-path2e-legacybreaks.pdf", margins: z, view: false))
        // 2f. limites de hifenização
        results.append(pathPrint(dir: dir, chapter: ch, url: urlLim, id: "2f", name: "igual a 2a com `hyphenate-limit-chars: 7 3 3` (+ -webkit-hyphenate-limit-before/after: 3)",
                                 file: "s7-path2f-limitchars.pdf", margins: z, view: false))
        // 2g. controle: widows/orphans = 1 (a propriedade tem efeito?)
        results.append(pathPrint(dir: dir, chapter: ch, url: urlWO, id: "2g", name: "controle: igual a 2a com `widows: 1; orphans: 1`",
                                 file: "s7-path2g-wo1.pdf", margins: z, view: false))
        // 2h/2i. fontes
        results.append(pathPrint(dir: dir, chapter: ch, url: urlIowan, id: "2h", name: "igual a 2a com fonte Iowan Old Style",
                                 file: "s7-path2h-iowan.pdf", margins: z, view: false))
        results.append(pathPrint(dir: dir, chapter: ch, url: urlNY, id: "2i", name: "igual a 2a com `ui-serif` (New York)",
                                 file: "s7-path2i-newyork.pdf", margins: z, view: false))
        // 2j/2k. melhor configuração conhecida
        var oBest = base; oBest.limitChars = true; oBest.limitLines = true
        results.append(pathPrint(dir: dir, chapter: ch, url: try write("best", oBest), id: "2j", name: "igual a 2a com `hyphenate-limit-chars: 7 3 3` e `-webkit-hyphenate-limit-lines: 2`",
                                 file: "s7-path2j-limitlines.pdf", margins: z, view: false))
        var oKeep = oBest; oKeep.keepWrap = true
        results.append(pathPrint(dir: dir, chapter: ch, url: try write("keep", oKeep), id: "2k", name: "2j + `<div class=keep>` (break-inside: avoid) envolvendo cada h2 e o 1º parágrafo",
                                 file: "s7-path2k-keepwrap.pdf", margins: z, view: false))
        // 3. NSPrintOperation(view:) sobre o WKWebView
        results.append(pathPrint(dir: dir, chapter: ch, url: urlA, id: "3", name: "NSPrintOperation(view: webView, printInfo:) — paginação automática",
                                 file: "s7-path3-view.pdf", margins: (14, 16, 18, 16), view: true))

        // métricas
        for i in results.indices {
            guard let pdf = results[i].pdf else { continue }
            results[i].m = analyze(pdf: pdf, chapter: ch, seconds: results[i].generateSeconds)
        }
        return report(results: results, chapter: ch, dir: dir)
    }

    // MARK: Caminhos

    static func makeView(url: URL, dir: URL) -> (WKWebView, NSWindow, Double, Bool, String) {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: pageW, height: pageH), configuration: cfg)
        let nav = S7Nav()
        web.navigationDelegate = nav
        objc_setAssociatedObject(web, "s7nav", nav, .OBJC_ASSOCIATION_RETAIN)
        let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: pageW, height: pageH), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        let t0 = now()
        web.loadFileURL(url, allowingReadAccessTo: dir)
        let ok = spin(30) { nav.done } && nav.error == nil
        _ = spin(0.5) { false } // layout/fontes assentam
        return (web, win, now() - t0, ok, nav.error ?? "")
    }

    static func pathCreatePDF(dir: URL, chapter: S7Chapter, url: URL) -> PathResult {
        var r = PathResult(id: "1", title: "WKWebView.createPDF(configuration:) — configuração padrão", note: "", pdf: nil,
                           generateSeconds: 0, loadSeconds: 0)
        let (web, win, load, ok, err) = makeView(url: url, dir: dir)
        _ = win
        r.loadSeconds = load
        guard ok else { r.note = "navegação falhou: \(err)"; return r }
        // altura do conteúdo, para o relatório
        let hbox = S7Box<Double>()
        web.evaluateJavaScript("document.documentElement.scrollHeight") { v, _ in hbox.value = (v as? Double) ?? -1 }
        _ = spin(5) { hbox.value != nil }
        let box = S7Box<Result<Data, Error>>()
        let t0 = now()
        web.createPDF(configuration: WKPDFConfiguration()) { res in box.value = res }
        guard spin(60, until: { box.value != nil }), let res = box.value else { r.note = "createPDF não retornou em 60 s"; return r }
        r.generateSeconds = now() - t0
        switch res {
        case .success(let data):
            let out = dir.appendingPathComponent("s7-path1-createpdf.pdf")
            try? data.write(to: out)
            r.pdf = out
            r.note = "viewport do WKWebView \(fmt(pageW)) × \(fmt(pageH)) pt; scrollHeight do documento \(fmt(hbox.value ?? -1, 0)) px"
        case .failure(let e): r.note = "createPDF falhou: \(e)"
        }
        return r
    }

    static func pathPrint(dir: URL, chapter: S7Chapter, url: URL, id: String, name: String, file: String,
                          margins: (t: CGFloat, l: CGFloat, b: CGFloat, r: CGFloat), view: Bool,
                          paper: NSSize? = nil) -> PathResult {
        var r = PathResult(id: id, title: name, note: "", pdf: nil, generateSeconds: 0, loadSeconds: 0)
        let (web, win, load, ok, err) = makeView(url: url, dir: dir)
        r.loadSeconds = load
        guard ok else { r.note = "navegação falhou: \(err)"; return r }
        let out = dir.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: out)

        let info = NSPrintInfo(dictionary: [:])
        let paperSize = paper ?? NSSize(width: pageW, height: pageH)
        info.paperSize = paperSize
        info.orientation = .portrait
        info.topMargin = margins.t; info.leftMargin = margins.l; info.bottomMargin = margins.b; info.rightMargin = margins.r
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out as NSURL

        let op: NSPrintOperation = view ? NSPrintOperation(view: web, printInfo: info) : web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        // o WKWebView exige frame não vazio para imprimir
        op.view?.frame = NSRect(x: 0, y: 0, width: paperSize.width - margins.l - margins.r, height: paperSize.height - margins.t - margins.b)
        let done = S7PrintDone()
        let t0 = now()
        op.runModal(for: win, delegate: done, didRun: #selector(S7PrintDone.didRun(_:success:contextInfo:)), contextInfo: nil)
        let finished = spin(90) { done.finished }
        r.generateSeconds = now() - t0
        let exists = FileManager.default.fileExists(atPath: out.path) && fileSize(out) > 0
        r.note = "runModal: finished=\(finished), success=\(done.success), arquivo=\(exists ? fmtMB(fileSize(out)) : "não gerado"); paperSize pedido \(fmt(paperSize.width)) × \(fmt(paperSize.height)), margens NSPrintInfo t/l/b/r = \(Int(margins.t))/\(Int(margins.l))/\(Int(margins.b))/\(Int(margins.r))"
        if exists { r.pdf = out }
        return r
    }

    // MARK: Análise

    static func countLetters(_ s: String) -> Int {
        s.decomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber }.count
    }

    static func words(_ s: String) -> [String] {
        s.decomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "-" })
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }.filter { !$0.isEmpty }
    }

    static func analyze(pdf: URL, chapter: S7Chapter, seconds: Double) -> S7Metrics {
        var m = S7Metrics()
        m.seconds = seconds
        m.fileBytes = fileSize(pdf)
        guard let doc = PDFDocument(url: pdf) else { return m }
        m.ok = true
        m.pages = doc.pageCount
        m.outline = doc.outlineRoot?.numberOfChildren ?? 0

        // fontes (reserva: texto cru; pode estar em object streams comprimidos)
        if let d = try? Data(contentsOf: pdf), let s = String(data: d, encoding: .isoLatin1),
           let re = try? NSRegularExpression(pattern: "/BaseFont\\s*/([A-Za-z0-9+_-]+)") {
            let ns = s as NSString
            var set = Set<String>()
            for mt in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) { set.insert(ns.substring(with: mt.range(at: 1))) }
            m.fonts = set.sorted()
        }

        var lines: [S7Line] = []
        var pageBoxes: [CGRect] = []
        for pi in 0..<doc.pageCount {
            guard let page = doc.page(at: pi) else { continue }
            let box = page.bounds(for: .mediaBox)
            pageBoxes.append(box)
            let key = "\(fmt(box.width)) × \(fmt(box.height))"
            m.sizes[key, default: 0] += 1
            if abs(box.width - pageW) <= 0.05, abs(box.height - pageH) <= 0.05 { m.sizeOK += 1 }
            guard let sel = page.selection(for: box) else { m.shortPages.append(pi + 1); continue }
            for l in sel.selectionsByLine() {
                guard let s = l.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { continue }
                var rect = l.bounds(for: page)
                rect.origin.x -= box.minX; rect.origin.y -= box.minY
                lines.append(S7Line(text: s, page: pi, rect: rect))
            }
        }
        m.lineCount = lines.count
        m.letters = lines.reduce(0) { $0 + countLetters($1.text) }
        m.sourceLetters = chapter.blocks.reduce(0) { $0 + countLetters($1.text) }

        // alinhamento linhas → blocos pela contagem de letras/dígitos
        var bi = 0, acc = 0
        var ok = true
        var starts: [Int: Int] = [:]
        var li = 0
        while li < lines.count, bi < chapter.blocks.count {
            let target = countLetters(chapter.blocks[bi].text)
            if starts[bi] == nil { starts[bi] = li }
            acc += countLetters(lines[li].text)
            lines[li].block = bi
            li += 1
            if acc == target { bi += 1; acc = 0 }
            else if acc > target { ok = false; m.alignNote = "excesso no bloco \(bi) (\(chapter.blocks[bi].kind)): linha \(li - 1) «\(lines[li - 1].text.prefix(40))» — \(acc) > \(target)"; break }
        }
        if ok, li != lines.count || bi != chapter.blocks.count { ok = false; m.alignNote = "sobra: linhas \(li)/\(lines.count), blocos \(bi)/\(chapter.blocks.count)" }
        m.aligned = ok

        var byBlock: [Int: [Int]] = [:]
        if ok { for (i, l) in lines.enumerated() { byBlock[l.block, default: []].append(i) } }
        if ok {
            for (_, idx) in byBlock { for (k, i) in idx.enumerated() { lines[i].indexInBlock = k; lines[i].linesInBlock = idx.count } }
        }

        // caracteres por linha: só corpo (parágrafos pt-BR, sem toc/títulos/nota)
        var interior: [Double] = [], nonFinal: [Double] = [], all: [Double] = []
        if ok {
            for l in lines where chapter.blocks[l.block].kind == .p {
                let c = Double(l.text.count)
                all.append(c)
                if l.indexInBlock < l.linesInBlock - 1 { nonFinal.append(c) }
                if l.indexInBlock > 0 && l.indexInBlock < l.linesInBlock - 1 { interior.append(c) }
            }
        } else {
            all = lines.map { Double($0.text.count) }
        }
        m.inRangePct = interior.isEmpty ? 0 : Double(interior.filter { $0 >= 55 && $0 <= 65 }.count) / Double(interior.count) * 100
        m.cplInterior = S7Stat(interior); m.cplNonFinal = S7Stat(nonFinal); m.cplAll = S7Stat(all)

        // extensão do texto na página
        if !lines.isEmpty, let box = pageBoxes.first {
            let minX = lines.map { $0.rect.minX }.min()!, maxX = lines.map { $0.rect.maxX }.max()!
            let top = lines.filter { $0.page == 0 }.map { $0.rect.maxY }.max() ?? 0
            m.extent = "x \(fmt(minX))–\(fmt(maxX)) pt (largura \(fmt(maxX - minX)) pt; margens esq. \(fmt(minX)) / dir. \(fmt(box.width - maxX))); topo da 1ª linha da p. 1 a \(fmt(box.height - top)) pt do topo"
            // base: menor minY de cada página (exceto a última), média
            var bottoms: [Double] = []
            // sem a 1ª página (sumário, quebra forçada) nem a última
            for p in 1..<max(doc.pageCount - 1, 1) {
                if let b = lines.filter({ $0.page == p }).map({ $0.rect.minY }).min() { bottoms.append(Double(b)) }
            }
            if !bottoms.isEmpty {
                m.fillMean = bottoms.reduce(0, +) / Double(bottoms.count)
                m.fillMedian = bottoms.sorted()[bottoms.count / 2]
                m.fillMin = bottoms.min()!
            }
        }

        // hifenização
        var vocab: [String: String] = [:] // palavra → idioma
        var compounds = Set<String>()
        for b in chapter.blocks where b.kind != .toc {
            for w in words(b.text) { vocab[w] = b.lang }
            for tok in b.text.split(separator: " ") where tok.dropFirst().dropLast().contains("-") {
                compounds.insert(String(tok.decomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }))
            }
        }
        var run = 0
        for (i, l) in lines.enumerated() {
            guard let last = l.text.last, hyphenChars.contains(last), i + 1 < lines.count else { run = 0; continue }
            run = (i > 0 && lines[i - 1].text.last.map(hyphenChars.contains) == true && lines[i - 1].page == l.page) ? run + 1 : 1
            m.maxHyphenRun = max(m.maxHyphenRun, run)
            let tokensA = l.text.split(separator: " ")
            let frag = String(tokensA.last ?? "").dropLast()
            let nextTok = lines[i + 1].text.split(separator: " ").first.map(String.init) ?? ""
            let nextWord = String(nextTok.prefix { $0.isLetter || $0.isNumber })
            let fragLetters = String(frag.filter { $0.isLetter || $0.isNumber })
            let joined = (fragLetters + nextWord).decomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
            if compounds.contains(String(joined)) { m.naturalHyphens += 1; continue }
            let lang = vocab[String(joined)] ?? "?"
            // idioma pelo bloco, quando alinhado; senão pelo vocabulário
            let key = ok ? chapter.blocks[l.block].lang : lang
            var e = m.hyphen[key] ?? (0, 0)
            e.total += 1
            let valid = vocab[String(joined)] != nil && fragLetters.count >= 2 && nextWord.count >= 2
            if valid { e.valid += 1 }
            if fragLetters.count < 3 || nextWord.count < 3 { m.shortFrag += 1 }
            m.hyphen[key] = e
            let desc = "\(key): \(fragLetters)‑|\(nextWord) → \(joined)"
            if valid { if m.hyphenSamples.count < 400 { m.hyphenSamples.append(desc) } } else { m.hyphenBad.append(desc) }
        }

        // viúvas, órfãs e títulos no pé
        if ok {
            for (bj, idx) in byBlock.sorted(by: { $0.key < $1.key }) {
                let kind = chapter.blocks[bj].kind
                guard kind == .p || kind == .note, idx.count >= 2 else { continue }
                var perPage: [Int: Int] = [:]
                for i in idx { perPage[lines[i].page, default: 0] += 1 }
                guard perPage.count > 1 else { continue }
                let pgs = perPage.keys.sorted()
                m.splitParas += 1
                m.splitPatterns[pgs.map { String(perPage[$0]!) }.joined(separator: "+"), default: 0] += 1
                let head = chapter.blocks[bj].text.prefix(36)
                if perPage[pgs.first!] == 1 { m.orphans.append("p. \(pgs.first! + 1): «\(head)…»") }
                if perPage[pgs.last!] == 1 { m.widows.append("p. \(pgs.last! + 1): «\(head)…»") }
            }
            for p in 0..<doc.pageCount {
                guard let lastIdx = lines.lastIndex(where: { $0.page == p }) else { continue }
                let b = chapter.blocks[lines[lastIdx].block]
                if b.kind == .h1 || b.kind == .h2 { m.headingsAtFoot.append("p. \(p + 1): «\(b.text)»") }
            }
        }

        // links
        var links: [(page: Int, rect: CGRect, destPage: Int?, destY: CGFloat?, uri: URL?)] = []
        for pi in 0..<doc.pageCount {
            guard let page = doc.page(at: pi) else { continue }
            let box = page.bounds(for: .mediaBox)
            for a in page.annotations where (a.type ?? "") == "Link" {
                var dest = a.destination
                if dest == nil, let g = a.action as? PDFActionGoTo { dest = g.destination }
                let uri = a.url ?? (a.action as? PDFActionURL)?.url
                var rect = a.bounds
                rect.origin.x -= box.minX; rect.origin.y -= box.minY
                var dp: Int?, dy: CGFloat?
                if let d = dest, let dpg = d.page { dp = doc.index(for: dpg); dy = d.point.y }
                links.append((pi, rect, dp, dy, uri))
            }
        }
        m.linksTotal = links.count
        m.linksGoTo = links.filter { $0.destPage != nil }.count
        m.linksURI = links.filter { $0.destPage == nil && $0.uri != nil }.count
        if ok {
            // sumário: cada entrada → página do h2 correspondente
            for (bj, b) in chapter.blocks.enumerated() where b.kind == .toc && b.target != nil {
                m.tocTotal += 1
                guard let tgt = chapter.blocks.firstIndex(where: { $0.kind == .h2 && $0.target == b.target }),
                      let srcLine = lines.first(where: { $0.block == bj }),
                      let dstLine = lines.first(where: { $0.block == tgt }) else { continue }
                let hit = links.first { $0.page == srcLine.page && $0.rect.insetBy(dx: -2, dy: -2).intersects(srcLine.rect) }
                if let h = hit, h.destPage == dstLine.page { m.tocOK += 1 }
            }
            // nota: marcador → nota; nota → marcador
            if let refB = chapter.blocks.firstIndex(where: { $0.html.contains("id=\"fnref1\"") }),
               let noteB = chapter.blocks.firstIndex(where: { $0.kind == .note }),
               let noteLine = lines.first(where: { $0.block == noteB }) {
                let refLines = lines.filter { $0.block == refB }
                m.noteRefOK = links.contains { l in
                    l.destPage == noteLine.page && refLines.contains { $0.page == l.page && $0.rect.insetBy(dx: -2, dy: -2).intersects(l.rect) }
                }
                let refPages = Set(refLines.map { $0.page })
                let noteLines = lines.filter { $0.block == noteB }
                m.noteBackOK = links.contains { l in
                    (l.destPage.map { refPages.contains($0) } ?? false) && noteLines.contains { $0.page == l.page && $0.rect.insetBy(dx: -2, dy: -2).intersects(l.rect) }
                }
            }
        }
        return m
    }

    // MARK: Relatório

    static func report(results: [PathResult], chapter: S7Chapter, dir: URL) -> SpikeResult {
        var md = Markdown()
        let src = chapter.blocks
        let bodyWords = chapter.bodyWordCount
        let enWords = src.filter { $0.lang == "en" }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let paras = src.filter { $0.kind == .p }.count
        let dlg = src.filter { $0.dialogue }.count
        md.heading(2, "Entrada")
        md.bullets([
            "Capítulo XHTML pt-BR gerado de forma determinística: \(bodyWords) palavras (títulos + corpo), \(paras) parágrafos (\(dlg) de diálogo), 1 h1, 6 h2, sumário com 6 links internos, 1 nota de rodapé (marcador `epub:type=\"noteref\"` + `<aside epub:type=\"footnote\">` no fim do capítulo), 1 parágrafo `lang=\"en\"` (\(enWords) palavras).",
            "Arquivos: `s7-chapter-A.xhtml` (`@page` com margens 14/16/18/16 pt), `s7-chapter-B.xhtml` (`@page` com margem 0), `s7-chapter-nohyph.xhtml` (controle com `hyphens: manual`).",
            "CSS: `@page { size: 328.64pt 500.47pt }`, `hyphens: auto` (html), corpo Charter 10,5 pt, entrelinha 1,4, `widows/orphans: 2`, `h1,h2 { break-after: avoid }`, `nav { break-after: page }`, alinhamento à esquerda, recuo de 1,2 em nos parágrafos.",
            "Carga por `loadFileURL` (MIME `application/xhtml+xml` pela extensão). Janela `NSWindow` borderless fora da tela; `NSApplication.shared` com política `.prohibited`.",
        ])

        md.heading(2, "Resumo por caminho")
        var rows: [[String]] = []
        for r in results {
            guard let m = r.m, m.ok else {
                rows.append([r.id, cell(r.title), "não gerou PDF", "—", "—", "—", "—", "—", "—", "—", fmt(r.generateSeconds, 2)])
                continue
            }
            let pt = m.hyphen["pt-BR"], en = m.hyphen["en"]
            let hy = "pt \(pt?.valid ?? 0)/\(pt?.total ?? 0) · en \(en?.valid ?? 0)/\(en?.total ?? 0)"
            let wo = m.aligned ? "\(m.widows.count) / \(m.orphans.count)" : "n/d"
            let lk = "\(m.linksGoTo) GoTo, \(m.linksURI) URI; sumário \(m.tocOK)/\(m.tocTotal); nota \(m.noteRefOK ? "sim" : "não") / volta \(m.noteBackOK ? "sim" : "não")"
            rows.append([r.id, cell(r.title), "\(m.pages)", "\(m.sizeOK)/\(m.pages)", m.cplInterior.n > 0 ? "\(fmt(m.cplInterior.mean, 1)) ± \(fmt(m.cplInterior.sd, 1))" : "n/d",
                         hy, wo, m.aligned ? "\(m.headingsAtFoot.count)" : "n/d", lk, fmtMB(m.fileBytes), fmt(r.generateSeconds, 2)])
        }
        md.table(["#", "caminho", "págs.", "pág. = alvo", "cpl (linhas internas, média ± dp)", "hífens válidos/total", "viúvas / órfãs", "títulos no pé", "links", "tamanho", "s"], rows)

        for r in results {
            md.heading(2, "Caminho \(r.id) — \(r.title)")
            md.para(r.note + ". Carga da página: \(fmt(r.loadSeconds, 2)) s; geração do PDF: \(fmt(r.generateSeconds, 2)) s.")
            guard let m = r.m, m.ok, let pdf = r.pdf else { md.para("**Sem PDF para medir.**"); continue }
            md.para("`\(pdf.lastPathComponent)` — \(fmtMB(m.fileBytes)).")
            var items: [String] = []
            items.append("Páginas: **\(m.pages)**; MediaBox: " + m.sizes.sorted { $0.value > $1.value }.map { "\($0.key) pt × \($0.value)" }.joined(separator: ", ") + "; iguais ao alvo (±0,05 pt): \(m.sizeOK)/\(m.pages).")
            items.append("Texto selecionável: \(m.letters) letras/dígitos extraídos de \(m.sourceLetters) esperados (\(fmt(Double(m.letters) / Double(max(m.sourceLetters, 1)) * 100, 1)) %); linhas extraídas: \(m.lineCount)" + (m.shortPages.isEmpty ? "" : "; páginas sem texto: \(m.shortPages.map(String.init).joined(separator: ","))") + ".")
            items.append("Alinhamento linhas → blocos do fonte: \(m.aligned ? "ok" : "**falhou** (\(m.alignNote)) — viúvas/órfãs e títulos no pé não medidos").")
            items.append("Caracteres por linha — linhas internas de parágrafo (sem 1ª e última): \(m.cplInterior.text); todas as não finais: \(m.cplNonFinal.text); todas as linhas de parágrafo: \(m.cplAll.text). Linhas internas dentro de 55–65: \(fmt(m.inRangePct, 1)) %.")
            if !m.extent.isEmpty { items.append("Extensão do texto: \(m.extent). Alvo: x 16–312,64 (296 pt), topo 14 pt, base 18 pt. Base da última linha (páginas 2 a n−1): média \(fmt(m.fillMean, 1)) pt, mediana \(fmt(m.fillMedian, 1)) pt, mín. \(fmt(m.fillMin, 1)) pt (a base da caixa tipográfica fica ≈ 3 pt abaixo da base do texto).") }
            let hy = m.hyphen.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.total) linhas terminadas em hífen, \($0.value.valid) com a palavra reconstituída válida" }.joined(separator: "; ")
            items.append("Hifenização automática: \(hy.isEmpty ? "**nenhuma linha termina em hífen**" : hy). Hífens próprios de palavra no fim de linha (guarda-chuva, adiantar-se): \(m.naturalHyphens). Quebras com fragmento < 3 letras: \(m.shortFrag). Maior sequência de linhas seguidas terminadas em hífen: \(m.maxHyphenRun). Hifenizadas / linhas não finais de parágrafo: \(fmt(Double(m.hyphen.values.reduce(0) { $0 + $1.total }) / Double(max(m.cplNonFinal.n, 1)) * 100, 1)) %.")
            if m.aligned {
                items.append("Parágrafos partidos entre páginas: \(m.splitParas) (linhas por página, ex. `2+1`): " + m.splitPatterns.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }.joined(separator: ", ") + ".")
                items.append("Viúvas: \(m.widows.count)\(m.widows.isEmpty ? "" : " — " + m.widows.joined(separator: "; ")). Órfãs: \(m.orphans.count)\(m.orphans.isEmpty ? "" : " — " + m.orphans.joined(separator: "; ")). Títulos na última linha da página: \(m.headingsAtFoot.count)\(m.headingsAtFoot.isEmpty ? "" : " — " + m.headingsAtFoot.joined(separator: "; ")).")
            }
            items.append("Links: \(m.linksTotal) anotações Link (\(m.linksGoTo) com destino interno, \(m.linksURI) só com URI). Sumário → h2 correto: \(m.tocOK)/\(m.tocTotal). Marcador → nota: \(m.noteRefOK ? "sim" : "não"); nota → marcador: \(m.noteBackOK ? "sim" : "não"). Outline (marcadores) no PDF: \(m.outline) itens.")
            items.append("Fontes (`/BaseFont` visível no arquivo): \(m.fonts.isEmpty ? "n/d (objetos comprimidos)" : m.fonts.joined(separator: ", ")).")
            md.bullets(items)
            if !m.hyphenSamples.isEmpty {
                let pt = m.hyphenSamples.filter { $0.hasPrefix("pt-BR") }.prefix(40)
                let en = m.hyphenSamples.filter { $0.hasPrefix("en") }.prefix(20)
                md.para("Quebras de palavra (fragmento esquerdo | direito → palavra): " + (pt + en).joined(separator: "; ") + ".")
            }
            if !m.hyphenBad.isEmpty { md.para("Quebras com palavra não reconstituível: " + m.hyphenBad.prefix(20).joined(separator: "; ") + ".") }
        }

        // linhas de resumo
        var summary: [String] = []
        for r in results {
            if let m = r.m, m.ok {
                let pt = m.hyphen["pt-BR"], en = m.hyphen["en"]
                summary.append("S7 \(r.id): \(m.pages) págs, alvo \(m.sizeOK)/\(m.pages), cpl \(fmt(m.cplInterior.mean, 1))±\(fmt(m.cplInterior.sd, 1)), hífens pt \(pt?.valid ?? 0)/\(pt?.total ?? 0) en \(en?.valid ?? 0)/\(en?.total ?? 0), viúvas \(m.widows.count) órfãs \(m.orphans.count), links sumário \(m.tocOK)/\(m.tocTotal), \(fmt(r.generateSeconds, 2)) s")
            } else {
                summary.append("S7 \(r.id): sem PDF (\(r.note))")
            }
        }
        return SpikeResult(markdown: md.text, summary: summary)
    }
}

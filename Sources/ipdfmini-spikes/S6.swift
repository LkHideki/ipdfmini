import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision

/// S6 — OCR para scans: Vision (RecognizeTextRequest e
/// RecognizeDocumentsRequest), `saveTextFromOCR` do PDFKit e camada de texto própria.
enum S6 {
    // MARK: - Tipos

    static let pageW: CGFloat = 595.2      // 2480 px a 300 dpi
    static let pageH: CGFloat = 841.92     // 3508 px a 300 dpi
    static let fonts = FontCache()

    /// Cache de CTFont sob lock: criar CTFont concorrentemente trava o processo.
    final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: CTFont] = [:]
        func font(_ name: String, _ size: CGFloat) -> CTFont {
            lock.lock(); defer { lock.unlock() }
            let key = "\(name)@\(size)"
            if let f = cache[key] { return f }
            let f = CTFontCreateWithName(name as CFString, size, nil)
            cache[key] = f
            return f
        }
    }

    struct TruthWord {
        var text: String
        var rect: CGRect        // tinta do glifo em pontos PDF (origem embaixo à esquerda)
        var origin: CGPoint
        var font: String
        var size: CGFloat
        var counts: Bool        // false: marcador (bullet), fora da verdade
    }

    struct Layout {
        var words: [TruthWord] = []
        var rules: [CGRect] = []
        var blocks: [String] = []       // parágrafos na ordem de leitura verdadeira
        var tableRows = 0, tableCols = 0, listItems = 0
    }

    struct Raster {
        var px: [UInt8]
        var w: Int
        var h: Int
        var dpi: Double
    }

    struct Variant: Sendable {
        let id: String
        let label: String
        let dpi: Double
        let rotation: CGFloat   // graus, anti-horário
    }

    static let variants: [Variant] = [
        Variant(id: "limpa", label: "limpa", dpi: 300, rotation: 0),
        Variant(id: "ruido", label: "ruído + fundo irregular", dpi: 300, rotation: 0),
        Variant(id: "inclinada", label: "inclinada 1,5°", dpi: 300, rotation: 1.5),
        Variant(id: "1bit", label: "1 bit (limiar)", dpi: 300, rotation: 0),
        Variant(id: "150dpi", label: "150 dpi", dpi: 150, rotation: 0),
    ]

    final class ImgBox: @unchecked Sendable {
        let cg: CGImage
        init(_ cg: CGImage) { self.cg = cg }
    }

    struct Case {
        let lang: String            // "pt-BR" ou "en"
        let variant: Variant
        let layout: Layout
        let img: ImgBox             // 8 bits, entrada da Vision
        let embed: ImgBox           // imagem embutida no PDF (1 bit na variação 1bit)
        let pdf: URL
        let truth: [String]         // palavras normalizadas
        var name: String { "\(lang) · \(variant.label)" }
    }

    struct OCRWord: Sendable {
        var text: String
        var bl: CGPoint, br: CGPoint, tr: CGPoint, tl: CGPoint   // pontos PDF
        var bbox: CGRect {
            let xs = [bl.x, br.x, tr.x, tl.x], ys = [bl.y, br.y, tr.y, tl.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    struct OCROut: Sendable {
        var tokens: [String] = []       // todas as palavras do texto, em ordem de observação
        var boxed: [OCRWord] = []       // palavras que ganharam caixa
        var lines = 0
        var ocrMs = 0.0
        var boxMs = 0.0
    }

    struct VConfig: Sendable {
        let name: String
        let fast: Bool
        let correction: Bool
        let langs: [String]?            // nil: detecção automática
        var minH: Float? = nil          // minimumTextHeightFraction (nil: padrão da API)
    }

    static let configs: [VConfig] = [
        VConfig(name: "acc · pt+en · corr", fast: false, correction: true, langs: ["pt-BR", "en-US"]),
        VConfig(name: "acc · pt+en · sem corr", fast: false, correction: false, langs: ["pt-BR", "en-US"]),
        VConfig(name: "acc · auto · corr", fast: false, correction: true, langs: nil),
        VConfig(name: "acc · auto · sem corr", fast: false, correction: false, langs: nil),
        VConfig(name: "fast · pt+en · corr · minH padrão", fast: true, correction: true, langs: ["pt-BR", "en-US"]),
        VConfig(name: "fast · pt+en · corr · minH 0", fast: true, correction: true, langs: ["pt-BR", "en-US"], minH: 0),
    ]

    // MARK: - Texto de verdade

    static let ptParas = [
        "A leitura de documentos digitais em telas pequenas exige decisões cuidadosas sobre o tamanho da letra, a largura da mancha e as margens. Quando o texto original foi composto para uma página maior, cada linha precisa ser reduzida ou reorganizada para caber, e essa transformação nem sempre preserva a legibilidade que o autor pretendia.",
        "Os livros escaneados trazem um problema adicional: a imagem da página não contém texto selecionável. Sem uma camada de reconhecimento óptico de caracteres, o leitor não consegue buscar palavras, copiar trechos nem consultar o dicionário. Por isso, o aplicativo precisa reconhecer cada palavra e gravar a posição exata de cada uma delas.",
        "A precisão do reconhecimento depende de vários fatores, entre eles a resolução da digitalização (de 150 a 600 dpi), o contraste entre a tinta e o papel, a inclinação das linhas e a presença de ruído. Páginas amareladas, com sombra na lombada ou com manchas de umidade costumam produzir mais erros, sobretudo nas palavras acentuadas e nos números.",
        "Em português, os acentos agudos, graves, circunflexos e o til mudam o significado das palavras. Há uma grande diferença entre sabia e sábia, entre pais e países, entre avó e avô. Um sistema que ignora essas marcas prejudica a busca e a pronúncia na função de leitura em voz alta, além de comprometer a tradução automática.",
        "Também é comum encontrar nomes próprios, siglas e termos técnicos que não aparecem em nenhum dicionário comum. A correção de linguagem ajuda quando a palavra é rara, mas pode atrapalhar quando troca um termo correto por outro mais frequente. Medir essa diferença com páginas de verdade é a única forma de decidir qual ajuste usar.",
        "Segundo a organização do projeto, a camada invisível deve acompanhar cada palavra com uma caixa estreita, ajustada à altura das letras. Assim, a seleção feita com o dedo cobre exatamente o trecho desejado, e o realce não invade a linha vizinha. Esse alinhamento precisa funcionar também em páginas ligeiramente inclinadas.",
        "O orçamento de tempo para o reconhecimento é de seiscentos milissegundos por página, valor que inclui a preparação da imagem e a gravação da camada de texto. Um livro de trezentas páginas, processado em paralelo, deveria ficar pronto em poucos minutos, sem consumir mais de um gigabyte de memória no computador.",
        "Os testes foram feitos com o corpo do texto entre dez e doze pontos, tamanho típico de romances, manuais e artigos científicos. Em corpos menores, as letras ocupam poucos pixels e o reconhecimento se torna mais frágil, principalmente quando a digitalização foi feita a cento e cinquenta pontos por polegada.",
        "Quando a página tem duas colunas, a ordem de leitura deixa de ser óbvia. O sistema precisa terminar a primeira coluna antes de começar a segunda, e não pode misturar as linhas de uma com as da outra. Tabelas, listas e legendas acrescentam ainda mais complexidade, porque seguem regras próprias de organização.",
        "Concluída a etapa de reconhecimento, o arquivo final deve abrir sem demora em qualquer leitor do iPad, preservando os marcadores, os links e o sumário. O leitor precisa encontrar a palavra procurada na primeira tentativa, mesmo que ela esteja escrita com maiúsculas, acentos ou sinais de pontuação diferentes.",
    ]

    static let enParas = [
        "Reading digital documents on a small screen demands careful decisions about type size, text width and margins. When the original text was set for a larger page, every line has to be shrunk or reflowed to fit, and that transformation does not always preserve the legibility the author intended.",
        "Scanned books bring an extra problem: the page image contains no selectable text. Without a layer of optical character recognition, the reader cannot search for words, copy passages or look up a definition in the dictionary. For that reason the application must recognize each word and record the exact position of every one of them.",
        "Recognition accuracy depends on several factors, among them the scanning resolution (from 150 to 600 dpi), the contrast between ink and paper, the slant of the lines and the presence of noise. Yellowed pages, shadows along the spine or moisture stains usually produce more mistakes, especially in numbers and in words with unusual spelling.",
        "In English the apostrophe, the hyphen and capital letters carry meaning that a careless engine may lose. There is a real difference between its and it's, between cooperate and co-operate, between polish and Polish. A system that ignores these marks harms searching and the pronunciation of the read aloud feature.",
        "It is also common to find proper names, acronyms and technical terms that appear in no ordinary dictionary. Language correction helps when a word is rare but can hurt when it replaces a correct term with a more frequent one. Measuring that difference on real pages is the only way to decide which setting to use.",
        "According to the project outline, the invisible layer should follow each word with a narrow box fitted to the height of the letters. That way a selection made with a finger covers exactly the desired passage, and the highlight does not spill into the neighboring line. This alignment must also work on slightly tilted pages.",
        "The time budget for recognition is six hundred milliseconds per page, a figure that includes preparing the image and writing the text layer. A book of three hundred pages, processed in parallel, should be finished in a few minutes without consuming more than one gigabyte of memory on the computer.",
        "The tests were made with body text between ten and twelve points, the typical size of novels, manuals and scientific articles. At smaller sizes the letters occupy few pixels and recognition becomes more fragile, mainly when the scan was made at one hundred and fifty dots per inch.",
        "When the page has two columns, the reading order stops being obvious. The system must finish the first column before starting the second and cannot mix the lines of one with those of the other. Tables, lists and captions add even more complexity because they follow their own rules of organization.",
        "Once recognition is complete, the final file should open without delay in any reader on the iPad, preserving bookmarks, links and the table of contents. The reader must find the sought word on the first attempt, even if it was typed with different capitals, accents or punctuation marks.",
    ]

    // MARK: - Normalização e alinhamento

    /// Minúsculas, sem pontuação; palavras vazias descartadas.
    static func norm(_ s: String) -> [String] {
        s.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { tok in
                let t = tok.filter { $0.isLetter || $0.isNumber }
                return t.isEmpty ? nil : String(t)
            }
    }

    static func stripMarks(_ w: String) -> String {
        String(String.UnicodeScalarView(w.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }))
    }

    static func hasMarks(_ w: String) -> Bool {
        w.decomposedStringWithCanonicalMapping.unicodeScalars.contains { $0.properties.generalCategory == .nonspacingMark }
    }

    /// Alinhamento monotônico verdade → obtido (distância de edição por palavra).
    /// Para cada palavra da verdade, o índice da palavra obtida pareada (ou nil).
    static func align(_ t: [String], _ g: [String]) -> [Int?] {
        let n = t.count, m = g.count
        var out = [Int?](repeating: nil, count: n)
        guard n > 0, m > 0 else { return out }
        let ts = t.map(stripMarks), gs = g.map(stripMarks)
        let W = m + 1
        var d = [Float](repeating: 0, count: (n + 1) * W)
        for i in 0...n { d[i * W] = Float(i) }
        for j in 0...m { d[j] = Float(j) }
        func cost(_ i: Int, _ j: Int) -> Float { t[i] == g[j] ? 0 : (ts[i] == gs[j] ? 0.3 : 1) }
        for i in 1...n {
            for j in 1...m {
                d[i * W + j] = min(d[(i - 1) * W + j - 1] + cost(i - 1, j - 1), d[(i - 1) * W + j] + 1, d[i * W + j - 1] + 1)
            }
        }
        var i = n, j = m
        while i > 0, j > 0 {
            if abs(d[i * W + j] - (d[(i - 1) * W + j - 1] + cost(i - 1, j - 1))) < 1e-4 {
                out[i - 1] = j - 1; i -= 1; j -= 1
            } else if abs(d[i * W + j] - (d[(i - 1) * W + j] + 1)) < 1e-4 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out
    }

    struct Acc {
        var exact = 0, total = 0, extras = 0
        var accOK = 0, accTotal = 0, accStripped = 0   // palavras acentuadas da verdade
        var rate: Double { total == 0 ? 0 : Double(exact) / Double(total) }
        var accentRate: Double? { accTotal == 0 ? nil : Double(accOK) / Double(accTotal) }
    }

    static func accuracy(truth t: [String], got g: [String]) -> Acc {
        let pairs = align(t, g)
        var a = Acc()
        a.total = t.count
        var paired = 0
        for (i, p) in pairs.enumerated() {
            let ok = p != nil && g[p!] == t[i]
            if p != nil { paired += 1 }
            if ok { a.exact += 1 }
            if hasMarks(t[i]) {
                a.accTotal += 1
                if ok { a.accOK += 1 }
                else if let p, stripMarks(g[p]) == stripMarks(t[i]) { a.accStripped += 1 }
            }
        }
        a.extras = max(0, g.count - paired)
        return a
    }

    /// Acurácia sem ordem: multiconjunto de palavras da verdade presentes na saída.
    static func bagAccuracy(truth t: [String], got g: [String]) -> Double {
        guard !t.isEmpty else { return 0 }
        var bag: [String: Int] = [:]
        for w in g { bag[w, default: 0] += 1 }
        var ok = 0
        for w in t where (bag[w] ?? 0) > 0 { bag[w]! -= 1; ok += 1 }
        return Double(ok) / Double(t.count)
    }

    static func upscale(_ img: CGImage, _ f: Double) -> CGImage? {
        let w = Int((Double(img.width) * f).rounded()), h = Int((Double(img.height) * f).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Páginas de verdade

    static func makeLine(_ s: String, _ font: CTFont) -> CTLine {
        let attrs = [kCTFontAttributeName as String: font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
    }

    static func metrics(_ s: String, _ font: CTFont) -> (adv: CGFloat, ink: CGRect) {
        let line = makeLine(s, font)
        let adv = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (adv, CTLineGetImageBounds(line, nil))
    }

    /// Quebra de linha gulosa; devolve false se faltou espaço.
    @discardableResult
    static func place(_ text: String, font fontName: String, size: CGFloat, x0: CGFloat, width: CGFloat,
                      y: inout CGFloat, leading: CGFloat, bottom: CGFloat = 60, counts: Bool = true,
                      into lay: inout Layout) -> Bool {
        let font = fonts.font(fontName, size)
        let space = metrics(" ", font).adv
        var x = x0
        for w in text.split(separator: " ").map(String.init) {
            let m = metrics(w, font)
            if x > x0, x + m.adv > x0 + width { x = x0; y -= leading }
            if y < bottom { return false }
            lay.words.append(TruthWord(text: w, rect: m.ink.offsetBy(dx: x, dy: y), origin: CGPoint(x: x, y: y),
                                       font: fontName, size: size, counts: counts))
            x += m.adv + space
        }
        y -= leading
        return true
    }

    static let body = "TimesNewRomanPSMT"
    static let bold = "TimesNewRomanPS-BoldMT"

    static func bodyPage(_ paras: [String]) -> Layout {
        var lay = Layout()
        var y: CGFloat = 780
        for p in paras {
            let before = lay.words.count
            let ok = place(p, font: body, size: 11, x0: 64, width: 467, y: &y, leading: 13.5, into: &lay)
            if lay.words.count > before { lay.blocks.append(p) }
            if !ok { break }
            y -= 5
        }
        return lay
    }

    static func twoColumnPage() -> Layout {
        var lay = Layout()
        var y: CGFloat = 790
        let title = "Relatório de leitura em telas pequenas"
        place(title, font: bold, size: 16, x0: 64, width: 467, y: &y, leading: 20, into: &lay)
        lay.blocks.append(title)
        let top: CGFloat = 740
        var y1 = top, y2 = top
        for p in ptParas[0..<4] { place(p, font: body, size: 10, x0: 64, width: 228, y: &y1, leading: 12.5, into: &lay); y1 -= 5; lay.blocks.append(p) }
        for p in ptParas[4..<8] { place(p, font: body, size: 10, x0: 303, width: 228, y: &y2, leading: 12.5, into: &lay); y2 -= 5; lay.blocks.append(p) }
        return lay
    }

    static func tablePage() -> Layout {
        var lay = Layout()
        var y: CGFloat = 790
        let title = "Resultados do teste de reconhecimento"
        place(title, font: bold, size: 16, x0: 64, width: 467, y: &y, leading: 20, into: &lay)
        lay.blocks.append(title)
        y -= 6
        let intro = "A tabela abaixo resume as medições feitas em cada variação da página, com o tempo médio por página e o total de palavras reconhecidas. Os recursos avaliados foram:"
        place(intro, font: body, size: 11, x0: 64, width: 467, y: &y, leading: 13.5, into: &lay)
        lay.blocks.append(intro)
        y -= 4
        for item in ["Seleção de texto com o dedo e realce por palavra",
                     "Busca por termos com acento e sem acento",
                     "Leitura em voz alta e tradução de trechos"] {
            var yy = y
            place("•", font: body, size: 11, x0: 70, width: 10, y: &yy, leading: 0, counts: false, into: &lay)
            place(item, font: body, size: 11, x0: 86, width: 440, y: &y, leading: 15, into: &lay)
            lay.blocks.append(item)
            lay.listItems += 1
        }
        y -= 14
        let rows = [["Variação", "Resolução", "Palavras", "Tempo"],
                    ["Limpa", "300 dpi", "540", "410 ms"],
                    ["Com ruído", "300 dpi", "540", "450 ms"],
                    ["Inclinada", "300 dpi", "540", "430 ms"],
                    ["Baixa resolução", "150 dpi", "540", "280 ms"]]
        let colW: [CGFloat] = [160, 100, 100, 107]
        let rowH: CGFloat = 24
        lay.tableRows = rows.count; lay.tableCols = colW.count
        var yTop = y
        for (r, row) in rows.enumerated() {
            var x: CGFloat = 64
            for (c, txt) in row.enumerated() {
                let rect = CGRect(x: x, y: yTop - rowH, width: colW[c], height: rowH)
                lay.rules.append(rect)
                var by = rect.minY + 8
                place(txt, font: r == 0 ? bold : body, size: 11, x0: x + 6, width: colW[c] - 8, y: &by, leading: 0, into: &lay)
                x += colW[c]
            }
            lay.blocks.append(row.joined(separator: " "))
            yTop -= rowH
        }
        y = yTop - 24
        let closing = "Concluída a medição, o arquivo final deve abrir sem demora em qualquer leitor do iPad, preservando os marcadores, os links e o sumário do documento original."
        place(closing, font: body, size: 11, x0: 64, width: 467, y: &y, leading: 13.5, into: &lay)
        lay.blocks.append(closing)
        return lay
    }

    // MARK: - Raster

    static func skewTransform(_ deg: CGFloat) -> CGAffineTransform {
        let c = CGPoint(x: pageW / 2, y: pageH / 2)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }

    static func draw(_ lay: Layout, in ctx: CGContext) {
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(0.6)
        for r in lay.rules { ctx.stroke(r) }
        for w in lay.words {
            ctx.textPosition = w.origin
            CTLineDraw(makeLine(w.text, fonts.font(w.font, w.size)), ctx)
        }
    }

    static func render(_ lay: Layout, dpi: Double, rotation: CGFloat = 0) -> Raster {
        let w = Int((Double(pageW) * dpi / 72).rounded()), h = Int((Double(pageH) * dpi / 72).rounded())
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let s = CGFloat(dpi / 72)
            ctx.scaleBy(x: s, y: s)
            if rotation != 0 { ctx.concatenate(skewTransform(rotation)) }
            draw(lay, in: ctx)
        }
        return Raster(px: px, w: w, h: h, dpi: dpi)
    }

    /// Fundo irregular (gradiente, sombra de lombada), ruído e salpicos; tinta levantada para ~50.
    static func scanify(_ r: inout Raster, seed: UInt64) {
        var s = seed | 1
        func rnd() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s >> 11) / Double(1 << 53)
        }
        let w = r.w, h = r.h
        for y in 0..<h {
            let fy = Double(y) / Double(h)
            for x in 0..<w {
                let fx = Double(x) / Double(w)
                var light = 0.80 + 0.20 * (0.5 + 0.5 * sin(fx * 5.0 + 0.7) * cos(fy * 3.2)) - 0.10 * fx * fy
                if fx < 0.06 { light *= 0.6 + 0.4 * fx / 0.06 }
                let v = Double(r.px[y * w + x]) / 255
                let n = (rnd() + rnd() + rnd() - 1.5) * 2 * 16
                r.px[y * w + x] = UInt8(clamping: Int((50 + v * 205) * light + n))
            }
        }
        for _ in 0..<250 {
            let cx = Int(rnd() * Double(w)), cy = Int(rnd() * Double(h)), rad = 1 + Int(rnd() * 2.5)
            let dark = 80 + Int(rnd() * 70)
            for dy in -rad...rad {
                for dx in -rad...rad where dx * dx + dy * dy <= rad * rad {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < w, y >= 0, y < h { r.px[y * w + x] = UInt8(clamping: Int(r.px[y * w + x]) - dark) }
                }
            }
        }
    }

    static func threshold(_ r: inout Raster) {
        for i in 0..<r.px.count { r.px[i] = r.px[i] < 128 ? 0 : 255 }
    }

    static func image8(_ r: Raster) -> CGImage? {
        guard let p = CGDataProvider(data: Data(r.px) as CFData) else { return nil }
        return CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: r.w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 1 bit por pixel, empacotado (1 = branco).
    static func image1(_ r: Raster) -> CGImage? {
        let bpr = (r.w + 7) / 8
        var bits = [UInt8](repeating: 0, count: bpr * r.h)
        for y in 0..<r.h {
            for x in 0..<r.w where r.px[y * r.w + x] >= 128 { bits[y * bpr + x / 8] |= UInt8(0x80 >> (x % 8)) }
        }
        guard let p = CGDataProvider(data: Data(bits) as CFData) else { return nil }
        return CGImage(width: r.w, height: r.h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bpr,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - PDF

    /// PDF de imagem (sem texto); com `layer`, acrescenta texto invisível (render mode 3) alinhado às caixas.
    static func writePDF(_ url: URL, image: CGImage, layer: [OCRWord]? = nil, rotate: Bool = true) throws {
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let aux = [kCGPDFContextCreator as String: "ipdfmini-spikes"] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux) else { throw SpikeError("PDF não criado: \(url.path)") }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        if let layer { drawLayer(ctx, words: layer, rotate: rotate) }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Uma só fonte (Helvetica 10 pt, em cache); o tamanho e a largura saem da matriz.
    static func drawLayer(_ ctx: CGContext, words ws: [OCRWord], rotate: Bool) {
        let font = fonts.font("Helvetica", 10)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        ctx.setTextDrawingMode(.invisible)
        ctx.setFillColor(gray: 0, alpha: 1)
        for w0 in ws {
            var w = w0
            if !rotate {   // caixa envolvente, sem girar (como o PDFKit faz)
                let b = w0.bbox
                w.bl = CGPoint(x: b.minX, y: b.minY); w.br = CGPoint(x: b.maxX, y: b.minY)
                w.tl = CGPoint(x: b.minX, y: b.maxY); w.tr = CGPoint(x: b.maxX, y: b.maxY)
            }
            let line = makeLine(w.text, font)
            let adv = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let width = hypot(w.br.x - w.bl.x, w.br.y - w.bl.y), height = hypot(w.tl.x - w.bl.x, w.tl.y - w.bl.y)
            guard adv > 0, width > 0, height > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: w.bl.x, y: w.bl.y)
            ctx.rotate(by: atan2(w.br.y - w.bl.y, w.br.x - w.bl.x))
            ctx.scaleBy(x: width / adv, y: height / (asc + desc))
            ctx.textPosition = CGPoint(x: 0, y: desc)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Vision

    final class Box<T: Sendable>: @unchecked Sendable { var value: Result<T, Error>? }

    /// Ponte síncrona para as APIs async do Vision (o spike roda no main).
    static func sync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try box.value!.get()
    }

    static func pdfPoint(_ p: NormalizedPoint, _ size: CGSize, _ dpi: Double) -> CGPoint {
        let q = p.toImageCoordinates(size, origin: .lowerLeft)
        return CGPoint(x: q.x * 72 / dpi, y: q.y * 72 / dpi)
    }

    static func recognize(_ img: ImgBox, dpi: Double, cfg: VConfig) async throws -> OCROut {
        var req = RecognizeTextRequest()
        req.recognitionLevel = cfg.fast ? .fast : .accurate
        req.usesLanguageCorrection = cfg.correction
        if let m = cfg.minH { req.minimumTextHeightFraction = m }
        if let l = cfg.langs {
            req.automaticallyDetectsLanguage = false
            req.recognitionLanguages = l.map { Locale.Language(identifier: $0) }
        } else {
            req.automaticallyDetectsLanguage = true
        }
        let t0 = now()
        let obs = try await req.perform(on: img.cg)
        let t1 = now()
        var out = OCROut()
        out.ocrMs = (t1 - t0) * 1000
        let size = CGSize(width: img.cg.width, height: img.cg.height)
        out.lines = obs.count
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            let s = cand.string
            var i = s.startIndex
            while i < s.endIndex {
                if s[i].isWhitespace { i = s.index(after: i); continue }
                var j = i
                while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
                let tok = String(s[i..<j])
                out.tokens.append(tok)
                if let r = cand.boundingBox(for: i..<j) {
                    out.boxed.append(OCRWord(text: tok,
                                             bl: pdfPoint(r.bottomLeft, size, dpi), br: pdfPoint(r.bottomRight, size, dpi),
                                             tr: pdfPoint(r.topRight, size, dpi), tl: pdfPoint(r.topLeft, size, dpi)))
                }
                i = j
            }
        }
        out.boxMs = (now() - t1) * 1000
        return out
    }

    struct DocOut: Sendable {
        var ms = 0.0
        var title: String?
        var paragraphs: [String] = []
        var paragraphBoxes: [CGRect] = []     // normalizadas, origem embaixo
        var lineCount = 0
        var tables: [[[String]]] = []
        var lists: [[String]] = []
        var fullText = ""
        var wordsExposed: Int?
    }

    static func recognizeDoc(_ img: ImgBox, langs: [String]?) async throws -> DocOut {
        var req = RecognizeDocumentsRequest()
        if let l = langs {
            req.textRecognitionOptions.automaticallyDetectLanguage = false
            req.textRecognitionOptions.recognitionLanguages = l.map { Locale.Language(identifier: $0) }
        }
        let t0 = now()
        let obs = try await req.perform(on: img.cg)
        var out = DocOut()
        out.ms = (now() - t0) * 1000
        guard let doc = obs.first?.document else { return out }
        out.title = doc.title?.transcript
        for p in doc.paragraphs {
            out.paragraphs.append(p.transcript)
            out.paragraphBoxes.append(p.boundingRegion.boundingBox.cgRect)
            out.lineCount += p.lines.count
        }
        out.tables = doc.tables.map { t in t.rows.map { row in row.map { $0.content.text.transcript } } }
        out.lists = doc.lists.map { l in l.items.map { $0.markerString + " | " + $0.itemString } }
        out.fullText = doc.text.transcript
        out.wordsExposed = doc.text.words?.count
        return out
    }

    // MARK: - findString e geometria

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }

    static func hIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let lo = max(a.minX, b.minX), hi = min(a.maxX, b.maxX)
        guard hi > lo else { return 0 }
        return Double((hi - lo) / (max(a.maxX, b.maxX) - min(a.minX, b.minX)))
    }

    static func boundingOfRotated(_ r: CGRect, _ deg: CGFloat) -> CGRect {
        deg == 0 ? r : r.applying(skewTransform(deg))
    }

    struct FindStat {
        var n = 0
        var found = 0, located = 0, foundNoMarks = 0, nNoMarks = 0
        var iou = 0.0, hiou = 0.0       // média do melhor casamento, sobre as achadas
        var iouAll = 0.0                // média sobre as 20 (achada fora do lugar e perdida = 0)
        var accented = 0
    }

    /// 20 palavras (10 acentuadas, quando existirem) únicas na página, espaçadas.
    static func pickWords(_ c: Case) -> [String] {
        let toks = c.layout.words.filter { $0.counts }.compactMap { norm($0.text).first }
        var freq: [String: Int] = [:]
        for t in toks { freq[t, default: 0] += 1 }
        var seen = Set<String>()
        let uniq = toks.filter { $0.count >= 6 && freq[$0] == 1 && seen.insert($0).inserted }
        let acc = uniq.filter(hasMarks), plain = uniq.filter { !hasMarks($0) }
        func spread(_ a: [String], _ k: Int) -> [String] {
            guard !a.isEmpty else { return [] }
            let k = min(k, a.count)
            return (0..<k).map { a[$0 * a.count / k] }
        }
        let a = spread(acc, acc.isEmpty ? 0 : 10)
        return a + spread(plain.filter { !a.contains($0) }, 20 - a.count)
    }

    static func findTest(_ doc: PDFDocument, _ c: Case) -> FindStat {
        var st = FindStat()
        guard let page = doc.page(at: 0) else { return st }
        for w in pickWords(c) {
            st.n += 1
            let marks = hasMarks(w)
            if marks { st.accented += 1 } else { st.nNoMarks += 1 }
            let truthRects = c.layout.words.filter { $0.counts && norm($0.text).first == w }
                .map { boundingOfRotated($0.rect, c.variant.rotation) }
            let sels = doc.findString(w, withOptions: [.caseInsensitive])
            if !sels.isEmpty { st.found += 1; if !marks { st.foundNoMarks += 1 } }
            var best = 0.0, bestH = 0.0
            for s in sels {
                let b = s.bounds(for: page)
                for t in truthRects {
                    let v = iou(b, t)
                    if v > best { best = v; bestH = hIoU(b, t) }
                }
            }
            if best >= 0.5 { st.located += 1 }
            if !sels.isEmpty { st.iou += best; st.hiou += bestH }
            st.iouAll += best
        }
        if st.found > 0 { st.iou /= Double(st.found); st.hiou /= Double(st.found) }
        if st.n > 0 { st.iouAll /= Double(st.n) }
        return st
    }

    /// Consulta sem acento deve achar a palavra acentuada (`diacriticInsensitive`).
    static func findNoDiacritics(_ doc: PDFDocument, _ c: Case) -> (found: Int, n: Int) {
        let ws = pickWords(c).filter(hasMarks)
        var f = 0
        for w in ws where !doc.findString(stripMarks(w), withOptions: [.caseInsensitive, .diacriticInsensitive]).isEmpty { f += 1 }
        return (f, ws.count)
    }

    /// Cobertura média das caixas da Vision sobre a verdade (palavras pareadas pelo alinhamento).
    static func boxVsTruth(_ c: Case, _ out: OCROut) -> (iou: Double, hiou: Double, n: Int) {
        let tw = c.layout.words.filter { $0.counts }.filter { norm($0.text).first != nil }
        let tk = tw.map { norm($0.text).first! }
        let bw = out.boxed.filter { norm($0.text).first != nil }
        let gk = bw.map { norm($0.text).first! }
        let pairs = align(tk, gk)
        var si = 0.0, sh = 0.0, n = 0
        for (i, p) in pairs.enumerated() {
            guard let p, gk[p] == tk[i] else { continue }
            let t = boundingOfRotated(tw[i].rect, c.variant.rotation)
            si += iou(bw[p].bbox, t); sh += hIoU(bw[p].bbox, t); n += 1
        }
        return n == 0 ? (0, 0, 0) : (si / Double(n), sh / Double(n), n)
    }

    // MARK: - Utilidades

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func pct(_ v: Double, _ digits: Int = 1) -> String { fmt(v * 100, digits) + "%" }

    static func ms(_ v: Double) -> String { fmt(v, 0) }

    static func trCount(_ url: URL) -> Int {
        guard let d = CGPDFDocument(url as CFURL), let p = d.page(at: 1) else { return -1 }
        let data = p.contentData()
        return countOccurrences("3 Tr", in: data)
    }

    /// Como a camada fica invisível: "BT=n Tr3=n ca0=n" (blocos de texto, render mode 3, ExtGState com alpha de preenchimento 0).
    static func invisibility(_ url: URL) -> String {
        guard let d = CGPDFDocument(url as CFURL), let p = d.page(at: 1) else { return "?" }
        let data = p.contentData()
        let bt = countOccurrences("BT", in: data), tr3 = countOccurrences("3 Tr", in: data)
        var ca0 = 0
        if let dict = p.dictionary {
            var res: CGPDFDictionaryRef?
            var eg: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let r = res, CGPDFDictionaryGetDictionary(r, "ExtGState", &eg), let e = eg {
                final class Cnt { var n = 0 }
                let cnt = Cnt()
                CGPDFDictionaryApplyBlock(e, { _, obj, _ in
                    var g: CGPDFDictionaryRef?
                    var ca: CGPDFReal = -1
                    if CGPDFObjectGetValue(obj, .dictionary, &g), let g, CGPDFDictionaryGetNumber(g, "ca", &ca), ca == 0 { cnt.n += 1 }
                    return true
                }, nil)
                ca0 = cnt.n
            }
        }
        return "BT \(bt) · 3 Tr \(tr3) · alpha 0: \(ca0)"
    }

    static func pdfFonts(_ url: URL) -> [String] {
        guard let d = CGPDFDocument(url as CFURL), let p = d.page(at: 1), let dict = p.dictionary else { return [] }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let r = res else { return [] }
        var fd: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(r, "Font", &fd), let f = fd else { return [] }
        final class Acc { var names: [String] = [] }
        let acc = Acc()
        CGPDFDictionaryApplyBlock(f, { key, _, _ in acc.names.append(String(cString: key)); return true }, nil)
        return acc.names
    }

    // MARK: - Execução

    struct TextRow {
        var acc: Acc
        var ms: Double
        var boxMs: Double
        var boxed: Int
        var tokens: Int
        var out: OCROut
    }

    static func execute(outPath: String) throws {
        let outURL = URL(fileURLWithPath: outPath)
        let dir = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = now()
        let r = try run(dir: dir)
        var head = Markdown()
        head.heading(1, "Resultados do spike S6 — OCR (Vision e PDFKit)")
        head.para("Gerado por `ipdfmini-spikes s6`. macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Duração total \(fmt(now() - t0, 0)) s.")
        try (head.text + "\n" + r.markdown).write(to: outURL, atomically: true, encoding: .utf8)
        print(r.summary.joined(separator: "\n"))
        print("markdown: \(outURL.path)")
    }

    static func run(dir: URL) throws -> SpikeResult {
        var md = Markdown()
        var summary: [String] = []

        // 1) Entradas
        print("s6: gerando páginas…")
        var cases: [Case] = []
        for (lang, paras) in [("pt-BR", ptParas), ("en", enParas)] {
            let lay = bodyPage(paras)
            let truth = lay.words.filter { $0.counts }.flatMap { norm($0.text) }
            for v in variants {
                var r = render(lay, dpi: v.dpi, rotation: v.rotation)
                if v.id == "ruido" { scanify(&r, seed: 7) }
                if v.id == "1bit" { threshold(&r) }
                guard let cg = image8(r) else { throw SpikeError("imagem não criada") }
                let pdf = dir.appendingPathComponent("s6-\(lang)-\(v.id).pdf")
                guard let embed = v.id == "1bit" ? image1(r) : cg else { throw SpikeError("imagem 1 bit não criada") }
                try writePDF(pdf, image: embed)
                cases.append(Case(lang: lang, variant: v, layout: lay, img: ImgBox(cg), embed: ImgBox(embed), pdf: pdf, truth: truth))
            }
        }
        func specialPage(_ lay: Layout, _ name: String) throws -> (Case) {
            let r = render(lay, dpi: 300)
            guard let cg = image8(r) else { throw SpikeError("imagem não criada") }
            let pdf = dir.appendingPathComponent("s6-pt-\(name).pdf")
            try writePDF(pdf, image: cg)
            return Case(lang: "pt-BR", variant: variants[0], layout: lay, img: ImgBox(cg), embed: ImgBox(cg), pdf: pdf,
                        truth: lay.words.filter { $0.counts }.flatMap { norm($0.text) })
        }
        let twoCol = try specialPage(twoColumnPage(), "2col")
        let tablePg = try specialPage(tablePage(), "table")

        md.heading(2, "Entradas")
        md.para("Página \(fmt(pageW, 1)) × \(fmt(pageH, 1)) pt (A4), Times New Roman 11 pt (pt-BR e en), \(cases[0].truth.count) palavras em pt-BR e \(cases[5].truth.count) em en (normalizadas: caixa e pontuação fora). Raster em cinza 8 bits a 300 dpi (2480 × 3508 px), embutido como PDF de imagem sem texto. Variações: limpa; ruído (σ ≈ 16 níveis) + fundo irregular (gradiente, sombra de lombada, 250 salpicos) com tinta levantada para ≈ 50; inclinada 1,5° na renderização; 1 bit por limiar 128 (PDF com imagem de 1 bit; a Vision recebe o equivalente de 8 bits com 0/255); 150 dpi (renderizada direto a 150 dpi). Mais duas páginas pt-BR para a estrutura: 2 colunas e com tabela + lista.")

        // 2) Vision RecognizeTextRequest
        print("s6: RecognizeTextRequest…")
        var rows: [[TextRow]] = []
        var cold: [Double] = []
        for cfg in configs {
            let first = cases[0].img
            let w0 = try sync { try await recognize(first, dpi: 300, cfg: cfg) }
            cold.append(w0.ocrMs)
            var cfgRows: [TextRow] = []
            for c in cases {
                var times: [Double] = [], boxTimes: [Double] = []
                var last = OCROut()
                for _ in 0..<3 {
                    let img = c.img, dpi = c.variant.dpi
                    last = try sync { try await recognize(img, dpi: dpi, cfg: cfg) }
                    times.append(last.ocrMs); boxTimes.append(last.boxMs)
                }
                let a = accuracy(truth: c.truth, got: last.tokens.flatMap(norm))
                cfgRows.append(TextRow(acc: a, ms: median(times), boxMs: median(boxTimes),
                                       boxed: last.boxed.count, tokens: last.tokens.count, out: last))
            }
            rows.append(cfgRows)
            print("s6:   \(cfg.name) ok")
        }

        md.heading(2, "1. RecognizeTextRequest")
        md.para("Três execuções por página e configuração; tempo = mediana de `perform(on:)` (sem a extração de caixas). Uma chamada de aquecimento por configuração (a primeira, a frio, carrega o modelo). Acurácia = palavras da verdade reconhecidas exatamente / palavras da verdade, com alinhamento monotônico por distância de edição (caixa e pontuação normalizadas).")
        md.para("Chamada a frio (primeira da configuração, página pt-BR limpa), ms: " + zip(configs, cold).map { "\($0.name) \(ms($1))" }.joined(separator: "; ") + ".")
        let hdr = ["entrada"] + configs.map(\.name)
        md.heading(3, "Acurácia por palavra")
        md.table(hdr, cases.enumerated().map { i, c in [c.name] + rows.map { pct($0[i].acc.rate) } })
        md.heading(3, "Palavras acentuadas corretas (pt-BR; exatas / total; entre parênteses, só o acento errado)")
        md.table(hdr, cases.enumerated().filter { $0.element.lang == "pt-BR" }.map { i, c in
            [c.name] + rows.map { r in
                let a = r[i].acc
                return "\(a.accOK)/\(a.accTotal) = \(pct(a.accentRate ?? 0)) (\(a.accStripped))"
            }
        })
        md.heading(3, "Tempo por página (mediana, ms)")
        md.table(hdr, cases.enumerated().map { i, c in [c.name] + rows.map { ms($0[i].ms) } })
        md.heading(3, "Caixas por palavra (`RecognizedText.boundingBox(for:)`): palavras com caixa / palavras; custo da extração (ms)")
        md.table(hdr, cases.enumerated().map { i, c in [c.name] + rows.map { "\($0[i].boxed)/\($0[i].tokens) · \(ms($0[i].boxMs))" } })

        // melhor configuração por acurácia média
        let means = rows.map { r in r.map { $0.acc.rate }.reduce(0, +) / Double(r.count) }
        let bestIdx = means.indices.max(by: { means[$0] < means[$1] }) ?? 0
        md.para("Acurácia média nas 10 entradas: " + zip(configs, means).map { "\($0.name) \(pct($1))" }.joined(separator: "; ") + ". Configuração usada nas etapas 3 e 4: **\(configs[bestIdx].name)**.")
        summary.append("Vision melhor config: \(configs[bestIdx].name), média \(pct(means[bestIdx]))")


        // ampliação antes da Vision
        print("s6: ampliação…")
        md.heading(3, "Experimento: ampliar a imagem antes da Vision")
        md.para("`minimumTextHeightFraction` padrão da API: \(RecognizeTextRequest().minimumTextHeightFraction) (nos níveis fast, o padrão devolveu 0 observações; com 0 explícito devolve texto). Configuração: \(configs[bestIdx].name); ampliação por interpolação alta do Quartz; acurácia sem ordem (multiconjunto) e com ordem; mediana de 2 execuções.")
        var expRows: [[String]] = []
        let expInputs: [(String, Case)] = [("pt-BR · ruído", cases[1]), ("en · 1 bit", cases[8]), ("pt-BR · 150 dpi", cases[4]), ("pt-BR · tabela + lista (300 dpi)", tablePg), ("pt-BR · 2 colunas (300 dpi)", twoCol)]
        for (label, c) in expInputs {
            for f in [1.0, 1.5, 2.0] {
                guard let big = f == 1 ? c.img.cg : upscale(c.img.cg, f) else { continue }
                let box = ImgBox(big)
                var times: [Double] = []
                var last = OCROut()
                let cfg = configs[bestIdx]
                for _ in 0..<2 { last = try sync { try await recognize(box, dpi: c.variant.dpi * f, cfg: cfg) }; times.append(last.ocrMs) }
                let got = last.tokens.flatMap(norm)
                expRows.append([label, "\(fmt(f, 1))× (\(big.width) × \(big.height))", pct(bagAccuracy(truth: c.truth, got: got)), pct(accuracy(truth: c.truth, got: got).rate), ms(median(times))])
            }
        }
        md.table(["entrada", "ampliação", "acurácia (sem ordem)", "acurácia (com ordem)", "ms"], expRows)

        // 3) RecognizeDocumentsRequest
        print("s6: RecognizeDocumentsRequest…")
        let docLangs = ["pt-BR", "en-US"]
        var docRows: [(acc: Acc, ms: Double)] = []
        for c in cases {
            var times: [Double] = []
            var last = DocOut()
            for k in 0..<3 {
                let img = c.img
                last = try sync { try await recognizeDoc(img, langs: docLangs) }
                _ = k
                times.append(last.ms)
            }
            docRows.append((accuracy(truth: c.truth, got: norm(last.fullText)), median(times)))
        }
        md.heading(2, "2. RecognizeDocumentsRequest")
        md.para("Idiomas [pt-BR, en-US], demais opções no padrão. Acurácia sobre `document.text.transcript`; tempo = mediana de 3 execuções.")
        md.table(["entrada", "acurácia", "acentos (pt)", "ms/página"], cases.enumerated().map { i, c in
            [c.name, pct(docRows[i].acc.rate), c.lang == "pt-BR" ? pct(docRows[i].acc.accentRate ?? 0) : "—", ms(docRows[i].ms)]
        })

        md.heading(3, "Estrutura devolvida (pt-BR, limpa, 300 dpi)")
        for (label, c) in [("2 colunas", twoCol), ("tabela + lista", tablePg)] {
            let img = c.img
            let d = try sync { try await recognizeDoc(img, langs: docLangs) }
            let textOut = try sync { try await recognize(img, dpi: 300, cfg: configs[bestIdx]) }
            md.para("**\(label)** — \(fmt(d.ms, 0)) ms. Título: \(d.title.map { "\"\(cell($0))\"" } ?? "nil"). Parágrafos: \(d.paragraphs.count) (linhas somadas: \(d.lineCount)); tabelas: \(d.tables.count); listas: \(d.lists.count); `text.words` exposto: \(d.wordsExposed.map(String.init) ?? "nil"). Verdade: \(c.layout.blocks.count) blocos" + (c.layout.tableRows > 0 ? ", tabela \(c.layout.tableRows) × \(c.layout.tableCols), lista de \(c.layout.listItems) itens" : "") + ".")
            let accDoc = accuracy(truth: c.truth, got: norm(d.fullText))
            let accTxt = accuracy(truth: c.truth, got: textOut.tokens.flatMap(norm))
            md.para("Ordem de leitura do texto completo (acurácia com alinhamento monotônico, sensível à ordem): RecognizeDocuments \(pct(accDoc.rate)); RecognizeText (linhas na ordem devolvida) \(pct(accTxt.rate)).")
            var lines: [String] = []
            for (i, p) in d.paragraphs.enumerated() {
                let b = d.paragraphBoxes[i]
                lines.append("P\(i + 1) x=\(fmt(b.minX, 2)) y_topo=\(fmt(b.maxY, 2)): \"\(cell(String(p.prefix(60))))…\"")
            }
            md.bullets(lines)
            for (ti, t) in d.tables.enumerated() {
                md.para("Tabela \(ti + 1): \(t.count) linhas × \(t.map(\.count).max() ?? 0) colunas. Células: " + t.map { $0.map(cell).joined(separator: " ¦ ") }.joined(separator: " // "))
            }
            for (li, l) in d.lists.enumerated() { md.para("Lista \(li + 1): " + l.map(cell).joined(separator: " // ")) }
            // ordem dos blocos verdadeiros entre os parágrafos devolvidos
            let gotKeys = d.paragraphs.map { Array(norm($0).prefix(4)) }
            let pos = c.layout.blocks.map { b -> Int? in
                let k = Array(norm(b).prefix(4))
                return gotKeys.firstIndex(of: k)
            }
            let found = pos.compactMap { $0 }
            let mono = zip(found, found.dropFirst()).allSatisfy { $0 < $1 }
            md.para("Blocos verdadeiros localizados entre os parágrafos (pelas 4 primeiras palavras): \(found.count)/\(pos.count); em ordem crescente: \(mono ? "sim" : "não"); posições: \(pos.map { $0.map(String.init) ?? "-" }.joined(separator: ",")).")
        }

        // 4) saveTextFromOCR
        print("s6: saveTextFromOCR…")
        struct PKRow { var acc = Acc(); var ms = 0.0; var ok = false; var timedOut = false; var inMemory = 0; var size = 0; var inv = ""; var url: URL? }
        var pk: [PKRow] = []
        var pkFirstString = 0
        for c in cases {
            var row = PKRow()
            let out = dir.appendingPathComponent("s6-ocr-\(c.lang)-\(c.variant.id).pdf")
            guard let doc = PDFDocument(url: c.pdf) else { pk.append(row); continue }
            pkFirstString += doc.string?.count ?? 0
            final class DocBox: @unchecked Sendable { let doc: PDFDocument; var ok = false; init(_ d: PDFDocument) { doc = d } }
            let b = DocBox(doc)
            let sem = DispatchSemaphore(value: 0)
            let t = now()
            DispatchQueue.global().async {
                b.ok = b.doc.write(to: out, withOptions: [.saveTextFromOCROption: true])
                sem.signal()
            }
            if sem.wait(timeout: .now() + 240) == .timedOut { row.timedOut = true; pk.append(row); break }
            row.ms = (now() - t) * 1000
            row.ok = b.ok
            row.inMemory = doc.string?.count ?? 0
            row.size = fileSize(out)
            row.url = out
            if let re = PDFDocument(url: out) {
                row.acc = accuracy(truth: c.truth, got: norm(re.string ?? ""))
            }
            row.inv = invisibility(out)
            pk.append(row)
            print("s6:   \(c.name) \(fmt(row.ms, 0)) ms")
        }
        md.heading(2, "3. `PDFDocumentWriteOption.saveTextFromOCROption`")
        md.para("O PDF de imagem é aberto (`doc.string` antes da gravação: \(pkFirstString) caracteres nas 10 entradas), gravado com `[.saveTextFromOCROption: true]` (uma execução por página, num thread de fundo com limite de 240 s) e reaberto; texto lido de `PDFDocument.string`. Não há parâmetro de idioma na API (`PDFDocument.h`: só \"@YES to enable\"). Última coluna do PDF de saída: blocos `BT`, ocorrências de `3 Tr` (render mode 3) e entradas de ExtGState com alpha de preenchimento 0.")
        md.table(["entrada", "gravou", "ms (gravação)", "acurácia", "acentos (pt)", "tamanho", "camada invisível", "`doc.string` em memória após gravar (caract.)"],
                 cases.enumerated().map { i, c in
                     guard i < pk.count else { return [c.name, "não rodou", "—", "—", "—", "—", "—", "—"] }
                     let r = pk[i]
                     if r.timedOut { return [c.name, "travou > 240 s", "—", "—", "—", "—", "—", "—"] }
                     return [c.name, r.ok ? "sim" : "não", ms(r.ms), pct(r.acc.rate),
                             c.lang == "pt-BR" ? pct(r.acc.accentRate ?? 0) : "—", fmtMB(r.size), r.inv, "\(r.inMemory)"]
                 })

        // 5) Camada própria
        print("s6: camada própria…")
        struct OwnRow { var find = FindStat(); var noDiac = (found: 0, n: 0); var acc = Acc(); var ms = 0.0; var size = 0; var inv = ""; var find2: FindStat? = nil; var iouVis = (iou: 0.0, hiou: 0.0, n: 0); var fonts: [String] = [] }
        var own: [OwnRow] = []
        var pkFind: [FindStat?] = []
        for (i, c) in cases.enumerated() {
            var r = OwnRow()
            let o = rows[bestIdx][i].out
            let url = dir.appendingPathComponent("s6-own-\(c.lang)-\(c.variant.id).pdf")
            let t = now()
            try writePDF(url, image: c.embed.cg, layer: o.boxed)
            r.ms = (now() - t) * 1000
            r.size = fileSize(url)
            r.inv = invisibility(url)
            r.fonts = pdfFonts(url)
            if let doc = PDFDocument(url: url) {
                r.find = findTest(doc, c)
                r.noDiac = findNoDiacritics(doc, c)
                r.acc = accuracy(truth: c.truth, got: norm(doc.string ?? ""))
            }
            r.iouVis = boxVsTruth(c, o)
            if c.variant.rotation != 0 {   // variante sem rotação por palavra (caixa envolvente)
                let url2 = dir.appendingPathComponent("s6-own-aa-\(c.lang)-\(c.variant.id).pdf")
                try writePDF(url2, image: c.embed.cg, layer: o.boxed, rotate: false)
                if let doc = PDFDocument(url: url2) { r.find2 = findTest(doc, c) }
            }
            own.append(r)
            if i < pk.count, let u = pk[i].url, let doc = PDFDocument(url: u) { pkFind.append(findTest(doc, c)) } else { pkFind.append(nil) }
        }
        md.heading(2, "4. Camada própria (caixas de palavra da Vision + texto invisível)")
        md.para("Texto do `\(configs[bestIdx].name)`; cada palavra é desenhada em render mode 3 (`CGContext.setTextDrawingMode(.invisible)`) com `CTLineDraw`, uma só fonte (Helvetica 10 pt, criada uma vez num cache sob lock) e a matriz ajustada à caixa: escala horizontal pela largura, vertical pela altura (ascendente + descendente = altura da caixa), rotação pelo ângulo da base. Teste: 20 palavras únicas da verdade (≥ 6 letras; 10 acentuadas em pt-BR) em `PDFDocument.findString(_, .caseInsensitive)`. \"no lugar\" = a melhor seleção tem IoU ≥ 0,5 com a caixa de tinta da verdade (inclinada: caixa envolvente da verdade girada). IoU 2D é sensível à convenção de altura (a seleção do PDFKit usa ascendente + descendente da fonte, a verdade é tinta); IoU horizontal compara só o intervalo em x.")
        md.table(["entrada", "achou", "no lugar", "IoU (achadas)", "IoU horiz.", "IoU média nas 20", "sem acento acha acentuada", "acurácia `string`", "camada invisível", "ms gravação", "tamanho"],
                 cases.enumerated().map { i, c in
                     let r = own[i]
                     return [c.name, "\(r.find.found)/\(r.find.n)", "\(r.find.located)/\(r.find.n)", fmt(r.find.iou, 2), fmt(r.find.hiou, 2), fmt(r.find.iouAll, 2),
                             c.lang == "pt-BR" ? "\(r.noDiac.found)/\(r.noDiac.n)" : "—", pct(r.acc.rate), r.inv, ms(r.ms), fmtMB(r.size)]
                 })
        md.para("Fontes no recurso da página da camada própria (ex.: \(own.first?.fonts.joined(separator: ", ") ?? "—")).")
        md.para("Nas páginas inclinadas, variante sem rotação por palavra (cada palavra com a caixa envolvente do quadrilátero, texto na horizontal, como o PDFKit faz): " + cases.enumerated().compactMap { i, c in own[i].find2.map { "\(c.name): achou \($0.found)/\($0.n), no lugar \($0.located)/\($0.n), IoU \(fmt($0.iou, 2)), IoU horiz. \(fmt($0.hiou, 2))" } }.joined(separator: "; ") + ".")
        md.heading(3, "Qualidade das caixas da Vision contra a verdade (palavras exatas pareadas)")
        md.table(["entrada", "palavras pareadas", "IoU 2D médio", "IoU horizontal médio"], cases.enumerated().map { i, c in
            [c.name, "\(own[i].iouVis.n)", fmt(own[i].iouVis.iou, 2), fmt(own[i].iouVis.hiou, 2)]
        })
        md.heading(3, "Mesmo teste de `findString` na saída do `saveTextFromOCR`")
        md.table(["entrada", "achou", "no lugar", "IoU (achadas)", "IoU horiz."], cases.enumerated().map { i, c in
            guard let f = pkFind[i] else { return [c.name, "—", "—", "—", "—"] }
            return [c.name, "\(f.found)/\(f.n)", "\(f.located)/\(f.n)", fmt(f.iou, 2), fmt(f.hiou, 2)]
        })

        // 6) Resumo
        md.heading(2, "Resumo (variação × método)")
        md.para("Vision-T = RecognizeTextRequest (\(configs[bestIdx].name)); Vision-D = RecognizeDocumentsRequest; PDFKit = `saveTextFromOCR`; própria = findString na camada própria (no lugar, de 20). Entradas: acurácia · acentos · ms/página.")
        md.table(["entrada", "Vision-T", "Vision-D", "PDFKit", "própria"], cases.enumerated().map { i, c in
            let t = rows[bestIdx][i]
            let acc = { (a: Acc) in c.lang == "pt-BR" ? pct(a.accentRate ?? 0) : "—" }
            let vt = "\(pct(t.acc.rate)) · \(acc(t.acc)) · \(ms(t.ms))"
            let vd = "\(pct(docRows[i].acc.rate)) · \(acc(docRows[i].acc)) · \(ms(docRows[i].ms))"
            let pr = i < pk.count ? "\(pct(pk[i].acc.rate)) · \(acc(pk[i].acc)) · \(ms(pk[i].ms))" : "—"
            return [c.name, vt, vd, pr, "\(own[i].find.located)/\(own[i].find.n)"]
        })
        for (i, c) in cases.enumerated() {
            summary.append("\(c.name): Vision-T \(pct(rows[bestIdx][i].acc.rate)) \(ms(rows[bestIdx][i].ms)) ms; Vision-D \(pct(docRows[i].acc.rate)) \(ms(docRows[i].ms)) ms; PDFKit \(i < pk.count ? pct(pk[i].acc.rate) : "—"); própria \(own[i].find.located)/\(own[i].find.n)")
        }
        return SpikeResult(markdown: md.text, summary: summary)
    }
}

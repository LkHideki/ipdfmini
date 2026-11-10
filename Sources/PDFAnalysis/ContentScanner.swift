import CoreGraphics

/// O que o content stream revela sem renderizar: onde há imagens e se há
/// texto visível. Usado para separar scan de página digital (§5.2) e no
/// refino da caixa de tinta (§5.3).
struct ContentSummary: Sendable, Equatable {
    /// Caixas (envoltórias) das imagens em espaço do usuário.
    var imageRects: [CGRect] = []
    var visibleTextOps = 0
    /// Texto com modo de renderização 3/7 (camada de OCR invisível).
    var invisibleTextOps = 0

    /// Fração de `box` coberta pela união das imagens (grade aproximada).
    func imageCoverage(of box: CGRect) -> Double {
        guard box.width > 0, box.height > 0, !imageRects.isEmpty else { return 0 }
        let n = 128
        var grid = [Bool](repeating: false, count: n * n)
        let cw = box.width / CGFloat(n), ch = box.height / CGFloat(n)
        for r in imageRects {
            let c = r.intersection(box)
            guard !c.isNull, !c.isEmpty else { continue }
            // células cujo centro cai dentro da imagem
            let x0 = max(0, Int(((c.minX - box.minX) / cw - 0.5).rounded(.up)))
            let x1 = min(n - 1, Int(((c.maxX - box.minX) / cw - 0.5).rounded(.down)))
            let y0 = max(0, Int(((c.minY - box.minY) / ch - 0.5).rounded(.up)))
            let y1 = min(n - 1, Int(((c.maxY - box.minY) / ch - 0.5).rounded(.down)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { grid[y * n + x] = true } }
        }
        return Double(grid.reduce(0) { $0 + ($1 ? 1 : 0) }) / Double(n * n)
    }
}

enum ContentScanner {
    static func scan(_ page: CGPDFPage) -> ContentSummary {
        let state = ScanState()
        guard let table = CGPDFOperatorTableCreate() else { return ContentSummary() }
        state.table = table
        install(table)
        let cs = CGPDFContentStreamCreateWithPage(page)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(cs, table, info)
        CGPDFScannerScan(scanner)
        return ContentSummary(imageRects: state.images, visibleTextOps: state.visibleText,
                              invisibleTextOps: state.invisibleText)
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func install(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "q") { _, info in
            let s = ContentScanner.state(info)
            s.stack.append(s.stack.last!)
        }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let s = ContentScanner.state(info)
            if s.stack.count > 1 { s.stack.removeLast() }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
            let s = ContentScanner.state(info)
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &v[i]) else { return }
            }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.stack[s.stack.count - 1].ctm = m.concatenating(s.stack[s.stack.count - 1].ctm)
        }
        CGPDFOperatorTableSetCallback(t, "Tr") { scanner, info in
            let s = ContentScanner.state(info)
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { s.stack[s.stack.count - 1].textMode = Int(mode) }
        }
        let show: CGPDFOperatorCallback = { _, info in
            let s = ContentScanner.state(info)
            let mode = s.stack.last!.textMode
            if mode == 3 || mode == 7 { s.invisibleText += 1 } else { s.visibleText += 1 }
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(t, op, show) }
        CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
            ContentScanner.state(info).handleDo(scanner)
        }
        // Imagens inline (BI…EI) não são contadas: costumam ser pequenas e o
        // scanner do Quartz não as expõe com geometria.
    }
}

private final class ScanState {
    struct Graphics { var ctm: CGAffineTransform = .identity; var textMode = 0 }
    var stack = [Graphics()]
    var images: [CGRect] = []
    var visibleText = 0
    var invisibleText = 0
    var table: CGPDFOperatorTableRef?
    var depth = 0

    func handleDo(_ scanner: CGPDFScannerRef) {
        var namePtr: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
        let cs = CGPDFScannerGetContentStream(scanner)
        guard let obj = CGPDFContentStreamGetResource(cs, "XObject", namePtr) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        let ctm = stack.last!.ctm
        switch String(cString: subtype) {
        case "Image":
            images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized)
        case "Form":
            // limite de profundidade contra ciclos de XObject
            guard depth < 8, let table else { return }
            var matrix = CGAffineTransform.identity
            var arr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                for i in 0..<6 { CGPDFArrayGetNumber(arr, i, &v[i]) }
                matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            }
            var res: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &res)
            let sub = CGPDFContentStreamCreateWithStream(stream, res ?? CGPDFStreamGetDictionary(stream)!, cs)
            // q/Q desbalanceado dentro do form não vaza para fora
            let saved = stack
            stack = [Graphics(ctm: matrix.concatenating(ctm), textMode: stack.last!.textMode)]
            depth += 1
            let s2 = CGPDFScannerCreate(sub, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(s2)
            depth -= 1
            stack = saved
        default:
            break
        }
    }
}

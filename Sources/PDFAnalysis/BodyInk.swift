import Accelerate
import CoreGraphics
import MiniGeometry

/// Tinta por linha de pixel do raster da análise (já sem marcas de corte,
/// carimbo e salpico), guardada até o cabeçalho/rodapé ser detectado no documento.
struct InkRows: Sendable, Equatable {
    var mapping: RasterMapping
    /// Geometria do raster (área visível) e a final da página.
    var g0: PageGeometry
    var g: PageGeometry
    /// Caixa efetiva em espaço de página de `g0`.
    var clip: CGRect
    /// Primeira coluna com tinta e coluna depois da última, por linha; -1 sem tinta.
    var minX: [Int32]
    var maxX: [Int32]

    /// Linhas com menos de `k` pixels não contam, como na caixa de tinta.
    init(mask: InkMask, rows: [Float], k: Float, mapping: RasterMapping, g0: PageGeometry, g: PageGeometry, clip: CGRect) {
        self.mapping = mapping
        self.g0 = g0
        self.g = g
        self.clip = clip
        let w = mask.width
        var lo = [Int32](repeating: -1, count: mask.height)
        var hi = [Int32](repeating: -1, count: mask.height)
        mask.values.withUnsafeBufferPointer { b in
            for y in 0..<mask.height where rows[y] >= k {
                let row = b.baseAddress! + y * w
                var x0 = 0
                while x0 < w && row[x0] == 0 { x0 += 1 }
                guard x0 < w else { continue }
                var x1 = w
                while x1 > x0 && row[x1 - 1] == 0 { x1 -= 1 }
                lo[y] = Int32(x0)
                hi[y] = Int32(x1)
            }
        }
        minX = lo
        maxX = hi
    }
}

/// Caixa de tinta sem cabeçalho/rodapé.
///
/// Vem do raster, nunca das caixas tipográficas: uma figura acima da primeira
/// linha de texto seria cortada. Exclui-se cada faixa contínua de linhas de
/// pixel com tinta que cruza um bloco `.headerFooter` e cabe nele (com folga de
/// `tolerancePt` para tinta de glifo além da caixa tipográfica). Faixa colada
/// no corpo (sem linha em branco entre os dois) fica: na dúvida, não remove.
enum BodyInk {
    static let tolerancePt: CGFloat = 2

    static func box(_ w: PageWork) -> CGRect? {
        guard let rows = w.inkRows, let ink = w.analysis.inkBox else { return nil }
        let blocks = w.analysis.blocks.filter { $0.type == .headerFooter }
        guard !blocks.isEmpty else { return nil }
        let map = rows.mapping
        let tol = Int((tolerancePt * map.pixelsPerPoint).rounded(.up))

        // faixas [y0, y1) de linhas com tinta
        var runs: [(Int, Int)] = []
        var start: Int?
        for y in rows.minX.indices {
            if rows.minX[y] >= 0 { if start == nil { start = y } } else if let s = start { runs.append((s, y)); start = nil }
        }
        if let s = start { runs.append((s, rows.minX.count)) }

        let bands = blocks.map { b -> (Int, Int) in
            let r = map.pixelRect(rows.g0.toPage(rows.g.toUser(b.rect)))
            return (r.y0, r.y1)
        }
        var excluded = [Bool](repeating: false, count: runs.count)
        for (i, run) in runs.enumerated() {
            excluded[i] = bands.contains { band in
                run.0 < band.1 && run.1 > band.0 && run.0 >= band.0 - tol && run.1 <= band.1 + tol
            }
        }
        guard excluded.contains(true) else { return nil }

        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
        for (i, run) in runs.enumerated() where !excluded[i] {
            y0 = min(y0, run.0)
            y1 = max(y1, run.1)
            for y in run.0..<run.1 {
                x0 = min(x0, Int(rows.minX[y]))
                x1 = max(x1, Int(rows.maxX[y]))
            }
        }
        // só cabeçalho/rodapé na página: nada a remover com segurança
        guard x1 > x0, y1 > y0 else { return nil }
        let s = map.pixelsPerPoint
        // meio pixel de folga pelo antialiasing, como na caixa de tinta
        let r0 = map.pageRect(pixelX: x0, y: y0, toX: x1, toY: y1).insetBy(dx: -0.5 / s, dy: -0.5 / s).intersection(rows.clip)
        guard !r0.isNull else { return nil }
        let r = rows.g.toPage(rows.g0.toUser(r0)).intersection(ink)
        return r.isNull || r.isEmpty ? nil : r
    }
}

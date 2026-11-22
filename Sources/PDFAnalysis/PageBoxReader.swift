import CoreGraphics
import MiniGeometry

/// Leitura das caixas de página.
enum PageBoxReader {
    /// Caixas em espaço do usuário e `/Rotate` normalizado.
    static func read(_ page: CGPDFPage) -> (boxes: PageBoxes, rotation: Int) {
        let media = page.getBoxRect(.mediaBox).standardized
        let crop = page.getBoxRect(.cropBox).standardized
        // getBoxRect devolve a CropBox quando Trim/Bleed/Art faltam; só o
        // dicionário diz se a caixa existe de fato (não são herdáveis).
        let dict = page.dictionary
        func optional(_ key: String, _ box: CGPDFBox) -> CGRect? {
            guard let dict else { return nil }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dict, key, &array) else { return nil }
            let r = page.getBoxRect(box).standardized
            return r.isEmpty ? nil : r
        }
        let boxes = PageBoxes(media: media, crop: crop,
                              trim: optional("TrimBox", .trimBox),
                              bleed: optional("BleedBox", .bleedBox),
                              art: optional("ArtBox", .artBox))
        return (boxes, PageGeometry.normalize(Int(page.rotationAngle)))
    }

    /// Área visível: CropBox ∩ MediaBox (MediaBox se a interseção for vazia).
    static func visibleBox(_ b: PageBoxes) -> CGRect {
        let r = b.crop.intersection(b.media)
        return r.isNull || r.isEmpty ? b.media : r
    }

    /// TrimBox candidata: existe e é menor que a área visível em algum lado.
    static func candidateTrim(_ b: PageBoxes, visible: CGRect) -> CGRect? {
        guard let t = b.trim else { return nil }
        let r = t.intersection(visible)
        guard !r.isNull, r.width > 1, r.height > 1 else { return nil }
        let tol: CGFloat = 0.5
        let smaller = r.minX > visible.minX + tol || r.minY > visible.minY + tol
            || r.maxX < visible.maxX - tol || r.maxY < visible.maxY - tol
        return smaller ? r : nil
    }
}

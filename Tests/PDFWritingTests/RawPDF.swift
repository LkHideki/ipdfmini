import Foundation
import CoreGraphics

extension TestPDF {
    /// PDF cru de 1 página com caixas e /Rotate à mão (o PDFKit normaliza a
    /// origem da MediaBox ao gravar, então não serve para criar esse caso).
    static func rawPDF(media: CGRect, crop: CGRect?, rotate: Int, content: String, to url: URL) throws {
        func box(_ r: CGRect) -> String { "[\(r.minX) \(r.minY) \(r.maxX) \(r.maxY)]" }
        let cropEntry = crop.map { " /CropBox \(box($0))" } ?? ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox \(box(media))\(cropEntry) /Rotate \(rotate) /Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(out.utf8).write(to: url)
    }
}

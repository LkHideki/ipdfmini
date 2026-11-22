// Spikes do M0: S1 Quartz, S2 PDFKit com caixas, S3 altura-x, S6 OCR, S7 WebKit.
// Uso: ipdfmini-spikes <s1|s2|s3|all|s6|s7> <arquivo-de-saída.md>
// Os PDFs gerados ficam no mesmo diretório do markdown.
import Foundation
import MiniGeometry

// S6 (OCR) e S7 (WebKit) ficam fora do `all`: rodam isolados (S6 leva ~3 min).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "s6" { try S6.execute(outPath: CommandLine.arguments[2]); exit(0) }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "s7" { S7.main(out: URL(fileURLWithPath: CommandLine.arguments[2])) }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "s5" { try S5.execute(dir: CommandLine.arguments[2]); exit(0) }

let args = CommandLine.arguments
guard args.count >= 3, ["s1", "s2", "s3", "all"].contains(args[1]) else {
    FileHandle.standardError.write(Data("uso: ipdfmini-spikes <s1|s2|s3|all> <saida.md>\n".utf8))
    exit(2)
}

let outURL = URL(fileURLWithPath: args[2])
let workDir = outURL.deletingLastPathComponent()
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

var sections: [String] = []
var summary: [String] = []
let which = args[1] == "all" ? ["s1", "s2", "s3"] : [args[1]]

for name in which {
    let t0 = now()
    let result: SpikeResult
    switch name {
    case "s1": result = try S1.run(dir: workDir)
    case "s2": result = try S2.run(dir: workDir)
    default: result = try S3.run(dir: workDir)
    }
    sections.append(result.markdown)
    summary += result.summary
    print("\(name) concluído em \(fmt(now() - t0, 1)) s")
}

var head = Markdown()
head.heading(1, "Resultados dos spikes M0 (S1–S3)")
head.para("Gerado por `ipdfmini-spikes \(args[1])`. Alvo: página do mini \(MiniPage.fullPortrait.width) × \(MiniPage.fullPortrait.height) pt. macOS \(ProcessInfo.processInfo.operatingSystemVersionString).")
try (head.text + "\n" + sections.joined(separator: "\n")).write(to: outURL, atomically: true, encoding: .utf8)
print(summary.joined(separator: "\n"))
print("markdown: \(outURL.path)")

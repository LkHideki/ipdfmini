// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ipdfmini",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ipdfmini", targets: ["ipdfmini-cli"]),
        .library(name: "MiniKit", targets: ["MiniKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MiniGeometry"),
        .target(name: "PDFAnalysis", dependencies: ["MiniGeometry"]),
        .target(name: "LayoutEngine", dependencies: ["MiniGeometry", "PDFAnalysis"]),
        .target(name: "PDFWriting", dependencies: ["MiniGeometry", "PDFAnalysis", "LayoutEngine", "QPDFKit"]),
        .target(name: "SyntheticCorpus", dependencies: ["MiniGeometry"]),
        .target(name: "MiniKit", dependencies: ["MiniGeometry", "PDFAnalysis", "LayoutEngine", "PDFWriting"]),
        .executableTarget(
            name: "ipdfmini-cli",
            dependencies: ["MiniKit", "SyntheticCorpus", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        // QPDFKit: gerador do S5 (colocações com clip, mesmo caminho do PlacementWriter).
        .executableTarget(name: "ipdfmini-spikes", dependencies: ["MiniGeometry", "QPDFKit"]),

        // libjpeg-turbo 3.2.1, C puro, sem SIMD. Obrigatório: Pl_DCT.hh do qpdf inclui jpeglib.h.
        // As .c com sufixo de precisão (src/wrapper) incluem as demais; por isso a lista é explícita.
        .target(
            name: "CJPEG",
            path: "Vendor/libjpeg-turbo",
            exclude: ["LICENSE.md", "README.ijg"],
            sources: [
                "src/wrapper",
                "src/jaricom.c", "src/jcapimin.c", "src/jcarith.c", "src/jchuff.c", "src/jcicc.c",
                "src/jcinit.c", "src/jclhuff.c", "src/jcmarker.c", "src/jcmaster.c", "src/jcomapi.c",
                "src/jcparam.c", "src/jcphuff.c", "src/jctrans.c", "src/jdapimin.c", "src/jdarith.c",
                "src/jdatadst.c", "src/jdatasrc.c", "src/jdhuff.c", "src/jdicc.c", "src/jdinput.c",
                "src/jdlhuff.c", "src/jdmarker.c", "src/jdmaster.c", "src/jdphuff.c", "src/jdtrans.c",
                "src/jerror.c", "src/jfdctflt.c", "src/jmemmgr.c", "src/jmemnobs.c", "src/jpeg_nbits.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        // qpdf 12.4.2 (crypto nativo, zlib do SDK) atrás de uma API C pura (capi/ipm_qpdf.h);
        // o C++ fica todo aqui dentro, então nenhum target Swift usa interoperabilidade C++.
        .target(
            name: "CQPDF",
            dependencies: ["CJPEG"],
            path: "Vendor/qpdf",
            exclude: ["LICENSE.txt", "NOTICE.md", "Artistic-2.0", "libqpdf/sph/md_helper.c"],
            sources: ["libqpdf", "ipm"],
            publicHeadersPath: "capi",
            cxxSettings: [
                .headerSearchPath("libqpdf"), .headerSearchPath("include"),
                // QTC::TC (cobertura de testes do qpdf) grava num map global sem lock:
                // SIGSEGV raro com documentos abertos em paralelo. Recurso do próprio qpdf.
                .define("QPDF_DISABLE_QTC"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "QPDFKit", dependencies: ["CQPDF"]),

        .testTarget(name: "MiniGeometryTests", dependencies: ["MiniGeometry"]),
        .testTarget(name: "PDFAnalysisTests", dependencies: ["PDFAnalysis", "SyntheticCorpus"]),
        .testTarget(name: "LayoutEngineTests", dependencies: ["LayoutEngine"]),
        .testTarget(name: "PDFWritingTests", dependencies: ["PDFWriting", "QPDFKit", "SyntheticCorpus"]),
        .testTarget(name: "SyntheticCorpusTests", dependencies: ["SyntheticCorpus"]),
        // ipdfmini-cli: o aceite do M1 roda `convert` pela própria CLI (executável testável).
        .testTarget(name: "MiniKitTests", dependencies: ["MiniKit", "SyntheticCorpus", "ipdfmini-cli"]),
        .testTarget(name: "QPDFKitTests", dependencies: ["QPDFKit"]),
    ],
    cxxLanguageStandard: .cxx20
)

// MARK: - App macOS (M2)
// Bloco à parte, acrescentado ao fim, para mesclar sem conflito com outros targets.
// Produto com nome distinto da CLI: "iPDFmini" e "ipdfmini" colidem em disco sem
// distinção de maiúsculas; o build-app.sh renomeia dentro do bundle.
package.products += [
    .executable(name: "iPDFminiApp", targets: ["iPDFminiApp"]),
]
package.targets += [
    .target(name: "AppCore", dependencies: ["MiniKit", "MiniGeometry", "PDFAnalysis", "LayoutEngine", "PDFWriting"]),
    .executableTarget(name: "iPDFminiApp", dependencies: ["AppCore", "MiniKit", "MiniGeometry", "LayoutEngine", "PDFWriting"]),
    // ipdfmini-cli: o executável da CLI é o processo filho dos testes de isolamento.
    .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "MiniKit", "LayoutEngine", "PDFAnalysis", "MiniGeometry", "QPDFKit", "ipdfmini-cli"]),
]

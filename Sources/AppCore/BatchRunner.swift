import Foundation
import MiniKit

/// Um documento a converter no lote, já com saída e ajustes resolvidos.
public struct BatchJob: Sendable, Equatable, Identifiable {
    public var id: String
    public var input: URL
    public var output: URL
    public var settings: ConversionSettings

    public init(id: String, input: URL, output: URL, settings: ConversionSettings) {
        self.id = id
        self.input = input
        self.output = output
        self.settings = settings
    }

    public var displayName: String { input.deletingPathExtension().lastPathComponent }
}

public enum BatchOutcome: Sendable, Equatable {
    /// Inclui saída com invariante reprovado (código 1 da CLI): o arquivo existe e o relatório diz o quê.
    case converted(ConversionReport)
    case failed(String)
    case cancelled
}

public struct BatchJobResult: Sendable, Equatable {
    public var job: BatchJob
    public var outcome: BatchOutcome
}

/// Estado de um documento na folha do lote.
public enum BatchJobState: Sendable, Equatable {
    case waiting, running, converted(passed: Bool), failed(String), cancelled

    public init(_ o: BatchOutcome) {
        switch o {
        case .converted(let r): self = .converted(passed: r.passed)
        case .failed(let m): self = .failed(m)
        case .cancelled: self = .cancelled
        }
    }

    public var title: String {
        switch self {
        case .waiting: "Aguardando"
        case .running: "Convertendo…"
        case .converted(let ok): ok ? "Convertido" : "Convertido com invariante reprovado"
        case .failed: "Falha"
        case .cancelled: "Cancelado"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .waiting, .running: false
        default: true
        }
    }
}

public enum BatchEvent: Sendable, Equatable {
    case started(String)
    case finished(String, BatchOutcome)
}

/// Fila do lote: no máximo `maxConcurrent` processos filhos ao mesmo tempo.
///
/// Cancelar a tarefa que chama `run` cancela as filhas; o `HelperProcess` mata os
/// processos em andamento (SIGTERM, depois SIGKILL) e os que não começaram saem
/// como cancelados. Saída parcial de falha ou cancelamento é apagada: os nomes
/// foram escolhidos livres, então nada de antes é perdido.
public enum BatchRunner {
    public static func run(_ jobs: [BatchJob], client: HelperClient, maxConcurrent: Int = 2,
                           onEvent: @escaping @MainActor @Sendable (BatchEvent) -> Void = { _ in }) async -> [BatchJobResult] {
        var outcomes = [BatchOutcome?](repeating: nil, count: jobs.count)
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (Int, BatchOutcome).self) { group in
            var next = 0
            while next < jobs.count, next < limit, !Task.isCancelled {
                let i = next
                await onEvent(.started(jobs[i].id))
                group.addTask { (i, await convert(jobs[i], client: client)) }
                next += 1
            }
            for await (i, outcome) in group {
                outcomes[i] = outcome
                await onEvent(.finished(jobs[i].id, outcome))
                if next < jobs.count, !Task.isCancelled {
                    let j = next
                    await onEvent(.started(jobs[j].id))
                    group.addTask { (j, await convert(jobs[j], client: client)) }
                    next += 1
                }
            }
        }
        var results: [BatchJobResult] = []
        for (i, job) in jobs.enumerated() {
            if let o = outcomes[i] {
                results.append(BatchJobResult(job: job, outcome: o))
            } else {
                await onEvent(.finished(job.id, .cancelled))
                results.append(BatchJobResult(job: job, outcome: .cancelled))
            }
        }
        return results
    }

    static func convert(_ job: BatchJob, client: HelperClient) async -> BatchOutcome {
        if Task.isCancelled { return .cancelled }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("não foi possível criar a pasta de destino: \(error.localizedDescription)")
        }
        let outcome: BatchOutcome
        do {
            outcome = .converted(try await client.convert(input: job.input, output: job.output, settings: job.settings))
        } catch {
            outcome = Task.isCancelled ? .cancelled : .failed(error.uiMessage)
        }
        if case .converted = outcome { return outcome }
        try? fm.removeItem(at: job.output)
        return outcome
    }
}

/// Resumo da folha final do lote: convertidos, falhas, avisos de legibilidade e
/// invariantes reprovados, com o nome do documento em cada linha.
public struct BatchSummary: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var name: String
        public var text: String
    }

    public var outputs: [URL] = []
    public var failures: [Line] = []
    public var legibilityWarnings: [Line] = []
    public var failedInvariants: [Line] = []
    /// Sumário que não chegou inteiro (deveria ser sempre vazio; o inv. 5 também acusa).
    public var outlineProblems: [Line] = []
    public var cancelled = 0
    public var total = 0

    public init(_ results: [BatchJobResult]) {
        total = results.count
        for r in results {
            let name = r.job.displayName
            switch r.outcome {
            case .cancelled: cancelled += 1
            case .failed(let m): failures.append(Line(name: name, text: m))
            case .converted(let rep):
                outputs.append(r.job.output)
                if let w = Self.legibility(rep) { legibilityWarnings.append(Line(name: name, text: w)) }
                for f in rep.validation?.failures ?? [] {
                    failedInvariants.append(Line(name: name, text: "\(f.id) · \(f.title): \(f.detail)"))
                }
                if let n = rep.navigation, !n.outlinePreserved {
                    outlineProblems.append(Line(name: name, text: OutlineDisplay.preserved(n)))
                }
            }
        }
    }

    public var convertedCount: Int { outputs.count }

    static func legibility(_ r: ConversionReport) -> String? {
        let c = r.chosen
        let pt = c.bodyPointSizeEquivalent.map { "\(Describe.number($0)) pt" } ?? "corpo não medido"
        switch c.tier {
        case "belowMinimum": return "corpo abaixo do mínimo legível (\(pt))"
        case "meetsMinimum": return "corpo abaixo do alvo de conforto (\(pt))"
        default: return nil
        }
    }

    /// "12 convertidos · 1 falha · 2 cancelados".
    public var headline: String {
        var parts = ["\(convertedCount) \(convertedCount == 1 ? "convertido" : "convertidos") de \(total)"]
        if !failures.isEmpty { parts.append("\(failures.count) \(failures.count == 1 ? "falha" : "falhas")") }
        if cancelled > 0 { parts.append("\(cancelled) \(cancelled == 1 ? "cancelado" : "cancelados")") }
        return parts.joined(separator: " · ")
    }

    public var shareItems: [URL] { ShareItems.urls(outputs) }
}

/// Itens para o AirDrop / compartilhar: só arquivos que existem, sem repetir.
/// Isolado do AppKit para ser testável (o envio em si exige um humano e um iPad).
public enum ShareItems {
    public static func urls(_ candidates: [URL?]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for case let u? in candidates {
            let r = FolderScanner.resolved(u)
            guard FileManager.default.fileExists(atPath: r.path), seen.insert(r.path).inserted else { continue }
            out.append(u)
        }
        return out
    }
}

/// Semáforo assíncrono: limita processos filhos de análise ao abrir pastas grandes.
public actor ConcurrencyLimiter {
    public let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit { running += 1; return }
        // A vaga passa direto de quem libera para quem espera (running não muda).
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let v = try await body()
            release()
            return v
        } catch {
            release()
            throw error
        }
    }
}

extension Error {
    /// Texto para a interface: `HelperError` já vem em português.
    var uiMessage: String { (self as? HelperError)?.message ?? String(describing: self) }
}

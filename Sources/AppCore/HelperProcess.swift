import Darwin
import Foundation

/// Resultado bruto de um processo filho.
public struct ProcessOutcome: Sendable, Equatable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
        case launchFailed(String)
    }

    public var termination: Termination
    public var stdout: Data
    public var stderr: Data
}

/// Executa um processo com limite de tempo, sem bloquear quem chama.
///
/// Os dois pipes são lidos em paralelo até o EOF: o JSON da análise passa fácil
/// dos 64 KB do buffer do pipe, e ler um só deixaria o filho travado escrevendo.
public enum HelperProcess {
    /// Folga entre SIGTERM e SIGKILL quando o tempo acaba.
    static let killGrace: TimeInterval = 2

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProcessOutcome {
        let state = RunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessOutcome, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runBlocking(executable, arguments, timeout, state))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func runBlocking(_ exe: URL, _ args: [String], _ timeout: TimeInterval, _ state: RunState) -> ProcessOutcome {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ProcessOutcome(termination: .launchFailed(error.localizedDescription), stdout: Data(), stderr: Data())
        }
        state.started(pid: p.processIdentifier)

        let buffers = Buffers()
        let group = DispatchGroup()
        for (handle, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                buffers.set(data, stdout: isOut)
                group.leave()
            }
        }
        let timer = DispatchWorkItem { state.timeOut() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        group.wait()
        p.waitUntilExit()
        timer.cancel()
        state.finished()

        let termination: ProcessOutcome.Termination
        if state.didTimeOut {
            termination = .timedOut
        } else if p.terminationReason == .uncaughtSignal {
            termination = .signaled(p.terminationStatus)
        } else {
            termination = .exited(p.terminationStatus)
        }
        return ProcessOutcome(termination: termination, stdout: buffers.stdout, stderr: buffers.stderr)
    }
}

/// Estado compartilhado entre a thread de espera, o temporizador e o cancelamento.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var done = false
    private var cancelled = false
    private(set) var didTimeOut = false

    func started(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let kill = cancelled
        lock.unlock()
        if kill { terminate() }
    }

    func finished() {
        lock.lock(); done = true; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        terminate()
    }

    func timeOut() {
        lock.lock(); didTimeOut = !done; lock.unlock()
        terminate()
    }

    /// SIGTERM e, se o filho ignorar, SIGKILL; nunca sinaliza um pid já colhido.
    private func terminate() {
        lock.lock()
        let target = pid, finished = done
        lock.unlock()
        guard target > 0, !finished else { return }
        Darwin.kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + HelperProcess.killGrace) { [self] in
            lock.lock()
            let still = !done
            lock.unlock()
            if still { Darwin.kill(target, SIGKILL) }
        }
    }
}

private final class Buffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()

    func set(_ d: Data, stdout: Bool) {
        lock.lock(); if stdout { out = d } else { err = d }; lock.unlock()
    }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
}

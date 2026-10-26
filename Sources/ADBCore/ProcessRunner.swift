import Foundation
import Darwin

public struct ProcessRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let executable: URL
    public let arguments: [String]
    public let standardInput: Data?
    public let timeout: TimeInterval
    public init(executable: URL, arguments: [String], standardInput: Data? = nil, timeout: TimeInterval = 8) {
        self.executable = executable; self.arguments = arguments
        self.standardInput = standardInput; self.timeout = timeout
    }
    public var description: String { "ADB process request (input and arguments omitted)" }
    public var debugDescription: String { description }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ProcessExecuting: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs only the requested executable. Both pipes are drained on a background queue,
/// even after their capture limits are reached. Neither arguments nor output are logged.
public struct ProcessRunner: ProcessExecuting {
    public let outputLimit: Int
    public init(outputLimit: Int = 256 * 1024) { self.outputLimit = max(1024, outputLimit) }

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try execute(request, flag: flag)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { flag.cancel() })
    }

    private func execute(_ request: ProcessRequest, flag: CancellationFlag) throws -> ProcessResult {
        guard !flag.cancelled else { throw CancellationError() }
        guard FileManager.default.isExecutableFile(atPath: request.executable.path) else { throw ADBError.unavailable }
        let process = Process()
        let output = Pipe(), error = Pipe(), input = Pipe()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.standardOutput = output; process.standardError = error; process.standardInput = input
        do { try process.run() } catch { throw ADBError.unavailable }
        // Closing the parent's write handles makes EOF observable when the child exits.
        try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = error.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close() }
        // Pairing input is tiny. Disable SIGPIPE for this pipe alone; no global signal changes.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let data = request.standardInput, data.count <= 4096 { try? input.fileHandleForWriting.write(contentsOf: data) }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()

        var stdout = Data(), stderr = Data(), exceeded = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, request.timeout)
        var failure: Error?
        func drain(_ fd: Int32, into capture: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound work per iteration so an endlessly writing child cannot defeat timeout.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                let remaining = max(0, outputLimit - capture.count)
                if count > remaining { exceeded = true }
                capture.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
        }
        while process.isRunning {
            drain(outFD, into: &stdout); drain(errFD, into: &stderr)
            if flag.cancelled { failure = CancellationError(); break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = ADBError.timeout; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if failure != nil, process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            // Escalate only this launched child, never the shared adb server or other processes.
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // Nonblocking drain also avoids hanging on a descendant that inherited a pipe.
        drain(outFD, into: &stdout); drain(errFD, into: &stderr)
        if let failure { throw failure }
        if exceeded { throw ADBError.outputLimit }
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }
}

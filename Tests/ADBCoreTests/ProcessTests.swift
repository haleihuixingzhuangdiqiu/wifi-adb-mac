import XCTest
@testable import ADBCore

final class ProcessTests: XCTestCase {
    func testConcurrentOutputPipesDoNotDeadlock() async throws {
        // A fixed local fixture only; this test never invokes adb or a mobile device.
        let script = "i=0; while [ $i -lt 6000 ]; do printf 'stdout0123456789\\n'; printf 'stderr0123456789\\n' >&2; i=$((i+1)); done"
        let result = try await ProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 8))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 6000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 6000)
    }
    func testOutputVolumeIsBoundedAndRejected() async {
        let script = "i=0; while [ $i -lt 2000 ]; do printf 'abcdefghijabcdefghij\\n'; i=$((i+1)); done"
        do {
            _ = try await ProcessRunner(outputLimit: 1024).run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]))
            XCTFail("over-limit output must not be accepted")
        } catch { XCTAssertEqual(error as? ADBError, .outputLimit) }
    }
    func testTimeoutTerminatesOnlyLaunchedChildPromptly() async {
        let start = Date()
        do {
            _ = try await ProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.15))
            XCTFail("must time out")
        } catch { XCTAssertEqual(error as? ADBError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCancellationStopsItsChild() async {
        let task = Task { try await ProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStdinDeliveredWithoutArguments() async throws {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: Data("fixture-input\n".utf8))
        let result = try await ProcessRunner().run(request)
        XCTAssertEqual(result.stdout, "fixture-input\n")
        XCTAssertTrue(request.arguments.isEmpty)
    }
    func testNonzeroExitReturnedAndClientErrorsDoNotExposeOutput() async throws {
        let result = try await ProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf private-diagnostic >&2; exit 7"]))
        XCTAssertEqual(result.status, 7)
        let executor = ScriptedExecutor([.init(["version"], "private-diagnostic", status: 7)])
        do {
            _ = try await ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor).version()
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? ADBError, .commandFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-diagnostic"))
        }
    }
}

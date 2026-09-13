import XCTest
@testable import TalkerCore

final class PiperJobTests: XCTestCase {
    func testMissingExecutableFailsInsteadOfReportingSpeech() throws {
        let job = PiperJob(executable: URL(fileURLWithPath: "/missing/orb-piper"), model: URL(fileURLWithPath: "/missing/voice"))
        XCTAssertThrowsError(try job.start(text: "Hello") { _ in XCTFail("Must not report playback") })
    }
    func testOwnedJobProducesArtifactAndCancelRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fake-piper")
        let argumentLog = folder.appendingPathComponent("args.txt")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentLog.path)'\nwhile [ $# -gt 0 ]; do case \"$1\" in --output-file) output=\"$2\"; shift;; esac; shift; done\nprintf 'test-audio' > \"$output\"\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let job = PiperJob(executable: executable, model: folder.appendingPathComponent("voice"),
                           settings: VoiceSettings(speed: 0.8, pause: 0.25, rhythm: 1.1))
        let done = expectation(description: "Owned process completion")
        var artifact: URL?
        try job.start(text: "Text; $(never run this)") { result in
            if case let .success(url) = result { artifact = url }
            else { XCTFail("Expected artifact") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        let url = try XCTUnwrap(artifact)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "test-audio")
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8)
        for pair in ["--length-scale\n1.25", "--sentence-silence\n0.25", "--noise-w-scale\n1.1"] {
            XCTAssertTrue(arguments.contains(pair), "Piper must receive \(pair)")
        }
        XCTAssertFalse(arguments.contains("Text;"), "Speech text must not appear in process arguments")
        job.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

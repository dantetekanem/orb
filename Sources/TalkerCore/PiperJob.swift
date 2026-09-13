import Foundation
import Darwin

public final class PiperJob {
    private let executable: URL
    private let model: URL
    private let settings: VoiceSettings
    private var process: Process?
    private var directory: URL?
    private var deadline: DispatchWorkItem?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var cancelled = false
    private var used = false

    public init(executable: URL, model: URL, settings: VoiceSettings = VoiceSettings()) {
        self.executable = executable; self.model = model; self.settings = settings.validated
    }

    public func start(text: String, completion: @escaping (Result<URL, Error>) -> Void) throws {
        precondition(Thread.isMainThread)
        guard !used else { throw APIError(500, "Speech job already used") }
        used = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orb-\(UUID().uuidString)")
        directory = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let input = folder.appendingPathComponent("input.txt")
            try Data(text.utf8).write(to: input)
            let task = Process()
            task.executableURL = executable
            task.arguments = ["--model", model.path, "--input-file", input.path,
                              "--output-file", folder.appendingPathComponent("speech.wav").path] + settings.arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            self.completion = completion
            process = task
            task.terminationHandler = { [self] _ in DispatchQueue.main.async { self.finished() } }
            try task.run()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let callback = self.completion else { return }
                self.cancel()
                callback(.failure(APIError(504, "Voice generation timed out")))
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        } catch {
            process?.terminationHandler = nil; process = nil; self.completion = nil
            cleanFiles()
            throw error
        }
    }

    public func cancel() {
        precondition(Thread.isMainThread)
        cancelled = true
        completion = nil
        deadline?.cancel(); deadline = nil
        if let process, process.isRunning {
            // Only the exact child owned by this job; never process-name or global cleanup.
            kill(process.processIdentifier, SIGKILL)
        } else { cleanFiles() }
    }

    private func finished() {
        deadline?.cancel(); deadline = nil
        let status = process?.terminationStatus
        process?.terminationHandler = nil; process = nil
        guard !cancelled, let callback = completion, let directory else { cleanFiles(); return }
        completion = nil
        let output = directory.appendingPathComponent("speech.wav")
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if status == 0 && (1...16_777_216).contains(size) { callback(.success(output)) }
        else {
            cleanFiles()
            callback(.failure(APIError(500, "Piper could not generate audio")))
        }
    }

    private func cleanFiles() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

import AVFoundation
import TalkerCore

// External synthesis/playback boundaries; tests replace these without producing sound.
protocol SpeechJob: AnyObject {
    func start(text: String, completion: @escaping (Result<URL, Error>) -> Void) throws
    func cancel()
}
extension PiperJob: SpeechJob {}

protocol SpeechPlayer: AnyObject {
    var currentTime: TimeInterval { get }
    var delegate: AVAudioPlayerDelegate? { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}
extension AVAudioPlayer: SpeechPlayer {}

enum SpeechAudio {
    static func load(_ url: URL) async throws -> (Data, AudioEnvelope) {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.length <= 12_000_000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw APIError(500, "Invalid voice audio")
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw APIError(500, "Unsupported audio format") }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            return (try Data(contentsOf: url), AudioEnvelope(samples: samples, sampleRate: file.processingFormat.sampleRate))
        }.value
    }
}

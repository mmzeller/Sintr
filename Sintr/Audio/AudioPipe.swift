import AVFoundation
import Foundation

/// Takes raw buffers from one audio source, converts them to the speech model's format,
/// hands them to the transcriber, and (optionally) saves them to a compressed audio file.
final class AudioPipe: @unchecked Sendable {
    let transcriber: LiveTranscriber
    /// The file this pipe is saving to, if saving worked.
    private(set) var fileURL: URL?

    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var _level: Float = 0
    private var _seconds: Double = 0
    private var _heardSound = false
    private var finished = false
    /// When this pipe started, on the system clock. Used to fill gaps (e.g. while the call app
    /// hasn't started playing yet, or while a device reconnects) with silence, so the two sides
    /// of a call stay lined up in time.
    private let startUptime = ProcessInfo.processInfo.systemUptime

    init(transcriber: LiveTranscriber, saveTo url: URL?) {
        self.transcriber = transcriber
        self.target = transcriber.format
        if let url {
            file = Self.openFile(at: url, format: target)
            fileURL = file?.url
        }
    }

    /// Recent loudness, 0…1, for the level meter.
    var level: Float { lock.withLock { _level } }
    /// Seconds of audio received so far.
    var seconds: Double { lock.withLock { _seconds } }
    /// Anything other than digital silence has come through (a muted or broken
    /// microphone delivers only zeros).
    var heardSound: Bool { lock.withLock { _heardSound } }

    /// Called on the audio thread for every captured buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, buffer.frameLength > 0 else { return }

        _level = max(Self.rms(buffer), _level * 0.8)
        if !_heardSound, Self.hasSound(buffer) { _heardSound = true }
        fillGapIfNeeded()

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return }

        write(output)
    }

    /// Sends converted audio to the transcriber and the file. Call with the lock held.
    private func write(_ output: AVAudioPCMBuffer) {
        _seconds += Double(output.frameLength) / target.sampleRate
        transcriber.feed(output)
        if let file {
            do {
                try file.write(from: output)
            } catch {
                // Stop trying to save rather than failing on every buffer; transcription carries on.
                self.file = nil
            }
        }
    }

    /// If audio stopped arriving for a while, add that much silence first. Call with the lock held.
    private func fillGapIfNeeded() {
        let missing = (ProcessInfo.processInfo.systemUptime - startUptime) - _seconds
        guard missing > 0.6 else { return }
        var remaining = AVAudioFrameCount((missing - 0.1) * target.sampleRate)
        let chunk = AVAudioFrameCount(target.sampleRate * 10)
        while remaining > 0 {
            let frames = min(remaining, chunk)
            guard let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
            silence.frameLength = frames
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            write(silence)
            remaining -= frames
        }
    }

    /// Stops accepting audio and closes the file.
    func finish() {
        lock.lock()
        finished = true
        file = nil
        lock.unlock()
    }

    // MARK: Helpers

    private static func openFile(at url: URL, format: AVAudioFormat) -> AVAudioFile? {
        // Compressed AAC keeps an hour of speech to roughly 15–30 MB.
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if let file = try? AVAudioFile(
            forWriting: url, settings: aac,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved) {
            return file
        }
        // Fall back to uncompressed audio if AAC isn't possible for this format.
        try? FileManager.default.removeItem(at: url)
        let cafURL = url.deletingPathExtension().appendingPathExtension("caf")
        return try? AVAudioFile(
            forWriting: cafURL, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    private static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frames = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        if let data = buffer.floatChannelData {
            for i in stride(from: 0, to: frames, by: 3) where data[0][i] != 0 { return true }
        } else if let data = buffer.int16ChannelData {
            for i in stride(from: 0, to: frames, by: 3) where data[0][i] != 0 { return true }
        }
        return false
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let samples = data[0]
            for i in stride(from: 0, to: frames, by: 4) { sum += samples[i] * samples[i] }
        } else if let data = buffer.int16ChannelData {
            let samples = data[0]
            for i in stride(from: 0, to: frames, by: 4) {
                let v = Float(samples[i]) / 32768
                sum += v * v
            }
        } else {
            return 0
        }
        let rms = (sum / Float((frames + 3) / 4)).squareRoot()
        // Map roughly -50 dB…0 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return min(max((db + 50) / 50, 0), 1)
    }
}

import AVFoundation
import Foundation

/// Takes raw buffers from one audio source, turns them into the speech model's format,
/// hands them to the transcriber, and saves them to a compressed audio file.
final class AudioPipe: @unchecked Sendable {
    let transcriber: LiveTranscriber
    /// The file this pipe is saving to, if saving worked.
    private(set) var fileURL: URL?

    private let label: String
    private let target: AVAudioFormat
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var _seconds: Double = 0
    private var _heardSound = false
    private var finished = false
    private var loggedFormat: String?
    private var convertFailures = 0
    /// When this pipe started, on the system clock. Gaps (while a call app hasn't started
    /// playing, or a device reconnects) are filled with silence so both sides of a call stay
    /// lined up in time.
    private let startUptime = ProcessInfo.processInfo.systemUptime

    init(transcriber: LiveTranscriber, saveTo url: URL?) {
        self.transcriber = transcriber
        self.target = transcriber.format
        self.label = transcriber.speaker.isEmpty ? "Microphone" : transcriber.speaker
        if let url {
            file = Self.openFile(at: url, format: target)
            fileURL = file?.url
            if file == nil { ActivityLog.add("\(label): couldn't create the audio file") }
        }
    }

    /// Seconds of audio received so far.
    var seconds: Double { lock.withLock { _seconds } }
    /// Something other than digital silence has come through.
    var heardSound: Bool { lock.withLock { _heardSound } }

    /// Called on the audio thread for every captured buffer (already mono, see `AudioHub`).
    func process(_ mono: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, mono.frameLength > 0 else { return }

        if !_heardSound, Self.hasSound(mono) {
            _heardSound = true
            ActivityLog.add("\(label): first sound after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startUptime)) s")
        }
        fillGapIfNeeded()

        if converter == nil || monoFormat != mono.format {
            monoFormat = mono.format
            converter = AVAudioConverter(from: mono.format, to: target)
            if converter == nil { ActivityLog.add("\(label): no converter from \(Int(mono.format.sampleRate)) Hz to the speech format") }
        }
        guard let converter else { return }
        let ratio = target.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up)) + 64
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
            return mono
        }
        guard status != .error, error == nil else {
            convertFailures += 1
            if convertFailures <= 3 { ActivityLog.add("\(label): conversion failed (\(error?.localizedDescription ?? "unknown"))") }
            self.converter = nil
            return
        }
        guard output.frameLength > 0 else { return }
        write(output)
    }

    /// Stops accepting audio and closes the file.
    func finish() {
        lock.lock()
        finished = true
        file = nil
        let total = _seconds
        lock.unlock()
        ActivityLog.add("\(label): stopped after \(String(format: "%.1f", total)) s of audio")
    }

    // MARK: Helpers (call with the lock held)

    private func write(_ output: AVAudioPCMBuffer) {
        _seconds += Double(output.frameLength) / target.sampleRate
        transcriber.feed(output)
        if let file {
            do {
                try file.write(from: output)
            } catch {
                ActivityLog.add("\(label): saving audio failed (\(error.localizedDescription)); transcription continues")
                self.file = nil
            }
        }
    }

    /// If audio stopped arriving for a while, add that much silence first — in half-second
    /// pieces, the way real audio arrives.
    private func fillGapIfNeeded() {
        let missing = (ProcessInfo.processInfo.systemUptime - startUptime) - _seconds
        guard missing > 0.6 else { return }
        if missing > 2 { ActivityLog.add("\(label): filling a \(String(format: "%.1f", missing)) s gap with silence") }
        var remaining = AVAudioFrameCount((missing - 0.1) * target.sampleRate)
        let chunk = AVAudioFrameCount(target.sampleRate / 2)
        while remaining > 0 {
            let frames = min(remaining, chunk)
            guard let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
            silence.frameLength = frames
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            write(silence)
            remaining -= frames
        }
    }

    // MARK: Shared audio helpers

    /// Any input as mono 32-bit float: one channel as-is, two averaged, more → the first one.
    /// Doing this ourselves avoids AVAudioConverter quietly producing silence for unusual
    /// microphone layouts (e.g. when Teams or FaceTime turns on voice processing).
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let both = channels == 2
        let interleaved = format.isInterleaved

        if let data = buffer.floatChannelData {
            for i in 0..<frames {
                let a = interleaved ? data[0][i * channels] : data[0][i]
                if both {
                    let b = interleaved ? data[0][i * channels + 1] : data[1][i]
                    dst[i] = (a + b) * 0.5
                } else {
                    dst[i] = a
                }
            }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<frames {
                let a = Float(interleaved ? data[0][i * channels] : data[0][i]) / 32768
                if both {
                    let b = Float(interleaved ? data[0][i * channels + 1] : data[1][i]) / 32768
                    dst[i] = (a + b) * 0.5
                } else {
                    dst[i] = a
                }
            }
        } else if let data = buffer.int32ChannelData {
            for i in 0..<frames {
                let a = Float(interleaved ? data[0][i * channels] : data[0][i]) / 2_147_483_648
                if both {
                    let b = Float(interleaved ? data[0][i * channels + 1] : data[1][i]) / 2_147_483_648
                    dst[i] = (a + b) * 0.5
                } else {
                    dst[i] = a
                }
            }
        } else {
            return nil
        }
        return out
    }

    static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData?[0] else { return false }
        for i in stride(from: 0, to: Int(buffer.frameLength), by: 3) where data[i] != 0 { return true }
        return false
    }

    /// Loudness of a mono float buffer, mapped from about -55 dB…0 dB to 0…1.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: frames, by: 2) { sum += data[i] * data[i] }
        let rms = (sum / Float((frames + 1) / 2)).squareRoot()
        // A garbled buffer (a device switching underneath us) can hold NaN or infinity.
        guard rms.isFinite else { return 0 }
        let db = 20 * log10(max(rms, 0.000_001))
        return min(max((db + 55) / 55, 0), 1)
    }

    static func describe(_ format: AVAudioFormat) -> String {
        let kind: String
        switch format.commonFormat {
        case .pcmFormatFloat32: kind = "float32"
        case .pcmFormatFloat64: kind = "float64"
        case .pcmFormatInt16: kind = "int16"
        case .pcmFormatInt32: kind = "int32"
        default: kind = "other"
        }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(kind)\(format.isInterleaved ? " interleaved" : "")"
    }

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
}

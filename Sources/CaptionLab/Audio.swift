import Accelerate
import AVFoundation
import Foundation

// MARK: - AVAsset+SafeTracks (verbatim from PalmierPro/Utilities/AVAsset+SafeTracks.swift)

/// Resume-once guard for completion handlers that may fire more than once.
private final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

extension AVAsset {
    /// Loads tracks of a media type, resuming exactly once.
    func tracksSafely(withMediaType mediaType: AVMediaType) async throws -> [AVAssetTrack] {
        struct Box: @unchecked Sendable { let tracks: [AVAssetTrack] }
        let once = OnceGuard()
        let box: Box = try await withCheckedThrowingContinuation { continuation in
            self.loadTracks(withMediaType: mediaType) { tracks, error in
                guard once.fire() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Box(tracks: tracks ?? []))
                }
            }
        }
        return box.tracks
    }
}

// MARK: - AudioTrackReader (verbatim from PalmierPro/Audio/AudioTrackReader.swift)

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    enum ReadError: Error {
        case noAudioTrack(String)
        case readFailed(String)

        var message: String {
            switch self {
            case .noAudioTrack(let name): "No audio track in \(name)"
            case .readFailed(let reason): reason
            }
        }
    }

    static func read(
        from url: URL,
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracksSafely(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            try onBuffer(pcm)
        }

        if reader.status == .failed {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
    }
}

// MARK: - AudioEnvelope (verbatim from PalmierPro/Audio/AudioEnvelope.swift)

struct AudioEnvelope: Sendable, Equatable {
    let hopSeconds: Double
    let samples: [Float]

    var duration: Double { Double(samples.count) * hopSeconds }

    /// Sub-envelope covering `range` of the SAME clip, re-based so sample 0 ≈ range.lowerBound — the contract
    /// `placeOnEnergyPeaks` expects (it treats sample i as `start + i·hop`). Passing a full-clip envelope
    /// where a span-based one is expected picks peaks from the wrong window — slice before handing down.
    func slice(_ range: ClosedRange<Double>) -> AudioEnvelope {
        guard hopSeconds > 0, !samples.isEmpty else { return self }
        let lo = max(0, min(samples.count, Int((range.lowerBound / hopSeconds).rounded(.down))))
        let hi = max(lo, min(samples.count, Int((range.upperBound / hopSeconds).rounded(.up)) + 1))
        guard lo < hi else { return AudioEnvelope(hopSeconds: hopSeconds, samples: []) }
        return AudioEnvelope(hopSeconds: hopSeconds, samples: Array(samples[lo..<hi]))
    }
}

enum AudioEnvelopeError: LocalizedError {
    case noAudioTrack(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name): "No audio track in \(name)."
        case .readFailed(let reason): "Could not read audio: \(reason)."
        }
    }
}

enum AudioEnvelopeExtractor {
    static let sampleRate: Double = 16_000
    static let hopSeconds: Double = 0.01

    static func extract(from url: URL, range: ClosedRange<Double>? = nil) async throws -> AudioEnvelope {
        let hopSize = max(1, Int((sampleRate * hopSeconds).rounded()))
        var samples: [Float] = []
        var sumSquares: Float = 0
        var carry = 0

        do {
            try await AudioTrackReader.read(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                guard let channel = pcm.floatChannelData else { return }
                let ptr = channel[0]
                let count = Int(pcm.frameLength)
                var i = 0
                while i < count {
                    let take = min(hopSize - carry, count - i)
                    var partial: Float = 0
                    vDSP_svesq(ptr + i, 1, &partial, vDSP_Length(take))
                    sumSquares += partial
                    carry += take
                    i += take
                    if carry == hopSize {
                        samples.append((sumSquares / Float(hopSize)).squareRoot())
                        sumSquares = 0
                        carry = 0
                    }
                }
            }
        } catch let error as AudioTrackReader.ReadError {
            switch error {
            case .noAudioTrack(let name): throw AudioEnvelopeError.noAudioTrack(name)
            case .readFailed(let reason): throw AudioEnvelopeError.readFailed(reason)
            }
        }

        if carry > 0 {
            samples.append((sumSquares / Float(carry)).squareRoot())
        }
        return AudioEnvelope(hopSeconds: hopSeconds, samples: samples)
    }
}

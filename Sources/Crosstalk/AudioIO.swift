import AVFoundation
import CoreMedia
import Foundation

enum ClipError: LocalizedError {
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let text): return text
        case .empty: return "That file has no samples."
        }
    }
}

enum ClipLoader {
    static func load(url: URL) throws -> Clip {
        let ext = url.pathExtension.lowercased()
        if ext == "wav" || ext == "wave",
           let data = try? Data(contentsOf: url),
           let clip = WAV.decodePCM16(
               data,
               name: url.deletingPathExtension().lastPathComponent,
               url: url
           ) {
            return clip
        }
        if let clip = loadPCMFile(url: url) {
            return clip
        }
        // AVAudioFile reports Opus-in-M4A as zero frames. AVAssetReader still decodes it.
        return try loadCompressedSync(url: url)
    }

    private static func loadPCMFile(url: URL) -> Clip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, format.channelCount >= 1, file.length > 0 else { return nil }
        let cap = AVAudioFramePosition((AppInfo.maxSongSeconds * rate).rounded(.down))
        let frames64 = min(file.length, max(1, cap))
        let frames = AVAudioFrameCount(frames64)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            return nil
        }
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        let stereo = channelCount > 1
        for i in 0..<count {
            let l = channels[0][i]
            left[i] = l.isFinite ? l : 0
            if stereo {
                let r = channels[1][i]
                right[i] = r.isFinite ? r : 0
            } else {
                right[i] = left[i]
            }
        }
        return Clip(
            name: url.deletingPathExtension().lastPathComponent,
            url: url,
            left: left,
            right: right,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: stereo ? 2 : 1,
            truncated: file.length > frames64
        )
    }

    private final class CompressedBox: @unchecked Sendable {
        var clip: Clip?
        var error: Error?
    }

    private static func loadCompressedSync(url: URL) throws -> Clip {
        let box = CompressedBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.clip = try await loadCompressed(url)
            } catch {
                box.error = error
            }
            sem.signal()
        }
        sem.wait()
        if let clip = box.clip { return clip }
        throw box.error ?? ClipError.unreadable("Couldn't read that audio file.")
    }

    private static func loadCompressed(_ url: URL) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw ClipError.unreadable("That file has no playable audio.")
        }
        let duration = try await asset.load(.duration)
        var rate = 48_000.0
        var sourceChannels = 2
        if let first = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { sourceChannels = Int(asbd.mChannelsPerFrame) }
        }
        let channelsOut = min(2, max(1, sourceChannels))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channelsOut,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw ClipError.unreadable("Couldn't read samples from that file.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipError.unreadable("Couldn't read samples from that file.")
        }

        let cap = Int((AppInfo.maxSongSeconds * rate).rounded(.down))
        let seconds = CMTimeGetSeconds(duration)
        let expected = seconds.isFinite && seconds > 0 ? Int((seconds * rate).rounded(.up)) + 8 : cap
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(min(cap, max(expected, 1)))
        right.reserveCapacity(min(cap, max(expected, 1)))

        while left.count < cap, let sample = output.copyNextSampleBuffer() {
            append(sample, channels: channelsOut, cap: cap, left: &left, right: &right)
            CMSampleBufferInvalidate(sample)
        }
        reader.cancelReading()
        guard !left.isEmpty else { throw ClipError.empty }
        let full = seconds.isFinite && seconds > AppInfo.maxSongSeconds + 0.05
        return Clip(
            name: url.deletingPathExtension().lastPathComponent,
            url: url,
            left: left,
            right: right,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: channelsOut > 1 ? 2 : 1,
            truncated: full || left.count >= cap
        )
    }

    private static func append(
        _ sample: CMSampleBuffer,
        channels: Int,
        cap: Int,
        left: inout [Float],
        right: inout [Float]
    ) {
        let frames = Int(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let take = min(frames, cap - left.count)
        guard take > 0 else { return }
        let byteCount = frames * channels * MemoryLayout<Float>.size
        guard CMBlockBufferGetDataLength(block) >= byteCount else { return }
        var pcm = [Float](repeating: 0, count: frames * channels)
        let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
            guard let dest = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: dest)
        }
        guard status == kCMBlockBufferNoErr else { return }
        if channels == 1 {
            for i in 0..<take {
                let value = pcm[i].isFinite ? pcm[i] : 0
                left.append(value)
                right.append(value)
            }
        } else {
            for i in 0..<take {
                let l = pcm[i * channels]
                let r = pcm[i * channels + 1]
                left.append(l.isFinite ? l : 0)
                right.append(r.isFinite ? r : 0)
            }
        }
    }
}

/// 16-bit export writes the XOR integers. 8-bit is scaled up so a player still hears full level.
enum ExportPCM {
    static func channels(_ take: Take) -> (left: [Int16], right: [Int16]) {
        guard take.bits == 8 else { return (take.left, take.right) }
        return (take.left.map(scaleEight), take.right.map(scaleEight))
    }

    /// The XOR repeated until `seconds`, cut at the last sample that fits.
    /// 8-bit values are scaled first, then copied, so every pass matches one-pass export.
    static func repeated(_ take: Take, seconds: Double) -> (left: [Int16], right: [Int16]) {
        let once = channels(take)
        let frames = frameCount(seconds: seconds, sampleRate: take.sampleRate)
        return (tile(once.left, count: frames), tile(once.right, count: frames))
    }

    /// Samples in a timed loop. Zero when the time is empty or not a number.
    /// Longer than the loaded-song cap is cut to that cap.
    static func frameCount(seconds: Double, sampleRate: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : AppInfo.renderRate
        let capped = min(seconds, AppInfo.maxSongSeconds)
        return max(0, Int((capped * rate).rounded()))
    }

    static func tile(_ samples: [Int16], count: Int) -> [Int16] {
        guard count > 0, let first = samples.first else { return [] }
        if samples.count == 1 { return [Int16](repeating: first, count: count) }
        if count <= samples.count { return Array(samples.prefix(count)) }
        var out = [Int16](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                guard let destination = dst.baseAddress, let source = src.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let n = min(src.count, count - offset)
                    destination.advanced(by: offset).update(from: source, count: n)
                    offset += n
                }
            }
        }
        return out
    }

    /// A clock for a whole second, or seconds with two decimals when the cut is not on a second.
    static func durationLabel(frames: Int, sampleRate: Double) -> String {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 1
        let seconds = Double(frames) / rate
        let whole = Int(seconds.rounded())
        if whole >= 1, abs(seconds - Double(whole)) < 0.05 {
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return String(format: "%.2f s", seconds)
    }

    static func scaleEight(_ v: Int16) -> Int16 {
        let y = Double(XORMath.dequantize(v, bits: 8))
        return Int16(clamping: Int((y * 32767).rounded()))
    }
}

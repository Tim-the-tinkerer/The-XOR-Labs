import AVFoundation
import Foundation

struct LiveWindow {
    var a: [Float]
    var b: [Float]
    var x: [Float]
    var qA: Int32
    var qB: Int32
    var qX: Int32
    var bits: Int
}

/// Plays a finished XOR. The callback reads integers that were already computed.
final class PlayEngine {
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var builtRate = 0.0
    private var wantPlay = false
    private var handlingRoute = false
    private var routeToken: NSObjectProtocol?

    private let lock = NSLock()
    private var take = Take.idle(caption: "", bits: 16, demo: true)
    private var gain = AppInfo.playbackGain
    private var playhead = 0

    private let ringCount = 2048
    private var ringA: [Float]
    private var ringB: [Float]
    private var ringX: [Float]
    private var ringWrite = 0
    private var ringFilled = 0
    private var lastA: Int32 = 0
    private var lastB: Int32 = 0
    private var lastX: Int32 = 0

    init() {
        ringA = [Float](repeating: 0, count: ringCount)
        ringB = [Float](repeating: 0, count: ringCount)
        ringX = [Float](repeating: 0, count: ringCount)
        routeToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
    }

    deinit {
        if let routeToken { NotificationCenter.default.removeObserver(routeToken) }
        engine.stop()
    }

    func setTake(_ take: Take) {
        lock.lock()
        let previous = self.take.sampleRate
        self.take = take
        if take.count == 0 || playhead >= take.count { playhead = 0 }
        ringWrite = 0
        ringFilled = 0
        let playing = wantPlay
        lock.unlock()
        guard playing, abs(previous - take.sampleRate) > 0.5 else { return }
        restart(rate: fileRate(take.sampleRate))
    }

    func setGain(_ value: Float) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        lock.lock()
        gain = next
        lock.unlock()
    }

    func start() throws {
        lock.lock()
        playhead = 0
        ringWrite = 0
        ringFilled = 0
        let rate = fileRate(take.sampleRate)
        lock.unlock()
        wantPlay = true
        if source == nil || abs(builtRate - rate) > 0.5 {
            build(rate: rate)
        }
        engine.mainMixerNode.outputVolume = 1
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stop() {
        wantPlay = false
        engine.mainMixerNode.outputVolume = 0
        if engine.isRunning { engine.pause() }
    }

    func snapshot() -> LiveWindow? {
        lock.lock()
        defer { lock.unlock() }
        guard ringFilled > 0 else { return nil }
        let n = ringFilled < ringCount ? ringFilled : ringCount
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        var x = [Float](repeating: 0, count: n)
        if ringFilled < ringCount {
            for i in 0..<n {
                a[i] = ringA[i]
                b[i] = ringB[i]
                x[i] = ringX[i]
            }
        } else {
            for i in 0..<n {
                let src = (ringWrite + i) % ringCount
                a[i] = ringA[src]
                b[i] = ringB[src]
                x[i] = ringX[src]
            }
        }
        return LiveWindow(a: a, b: b, x: x, qA: lastA, qB: lastB, qX: lastX, bits: take.bits)
    }

    /// One file sample per device frame plays a 22050 Hz XOR at 48000 and does not match the export.
    /// The node stays at the file rate. The engine converts to the output device.
    private func fileRate(_ rate: Double) -> Double {
        rate > 0 ? rate : AppInfo.renderRate
    }

    private func handleRouteChange() {
        guard !handlingRoute else { return }
        handlingRoute = true
        defer { handlingRoute = false }
        let resume = wantPlay
        lock.lock()
        let rate = fileRate(take.sampleRate)
        lock.unlock()
        build(rate: rate)
        guard resume else { return }
        engine.mainMixerNode.outputVolume = 1
        do {
            try engine.start()
        } catch {
            wantPlay = false
            onFailure?(error.localizedDescription)
        }
    }

    private func restart(rate: Double) {
        build(rate: rate)
        engine.mainMixerNode.outputVolume = 1
        do {
            try engine.start()
        } catch {
            wantPlay = false
            onFailure?(error.localizedDescription)
        }
    }

    /// Renders `frameCount` frames at `outputRate` without opening the speakers.
    /// Used to prove a file keeps its own rate on the way to the device.
    func renderOffline(outputRate: Double, frameCount: Int) -> [Float]? {
        guard frameCount > 0, outputRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else {
            return nil
        }
        engine.stop()
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        } catch {
            return nil
        }
        let rate = fileRate(take.sampleRate)
        build(rate: rate)
        engine.mainMixerNode.outputVolume = 1
        do {
            try engine.start()
        } catch {
            engine.disableManualRenderingMode()
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            engine.stop()
            engine.disableManualRenderingMode()
            return nil
        }
        var left: [Float] = []
        left.reserveCapacity(frameCount)
        var remaining = frameCount
        var failed = false
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(4096, remaining))
            buffer.frameLength = chunk
            do {
                let status = try engine.renderOffline(chunk, to: buffer)
                guard status == .success else {
                    failed = true
                    break
                }
            } catch {
                failed = true
                break
            }
            let got = Int(buffer.frameLength)
            guard got > 0, let channels = buffer.floatChannelData else {
                failed = true
                break
            }
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: got))
            remaining -= got
        }
        engine.stop()
        engine.disableManualRenderingMode()
        source = nil
        builtRate = 0
        if failed || left.isEmpty { return nil }
        return left
    }

    private func build(rate: Double) {
        engine.stop()
        if let source {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
            self.source = nil
        }
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            return self.render(frameCount: frameCount, list: abl)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        builtRate = rate
    }

    private func render(frameCount: AVAudioFrameCount, list: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(list)
        let frames = Int(frameCount)
        guard frames > 0, abl.count >= 2,
              let lRaw = abl[0].mData, let rRaw = abl[1].mData else { return noErr }
        let leftOut = lRaw.assumingMemoryBound(to: Float.self)
        let rightOut = rRaw.assumingMemoryBound(to: Float.self)
        let leftN = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        let rightN = Int(abl[1].mDataByteSize) / MemoryLayout<Float>.size
        let n = min(frames, leftN, rightN)
        guard n > 0 else { return noErr }

        lock.lock()
        defer { lock.unlock() }
        let current = take
        let level = gain
        let total = current.count
        let bits = current.bits
        guard total > 0 else {
            for i in 0..<n {
                leftOut[i] = 0
                rightOut[i] = 0
            }
            return noErr
        }
        let traceNow = current.traceNow
        let traceDelayed = current.traceDelayed
        var head = playhead
        for i in 0..<n {
            if head >= total { head = 0 }
            let sampleL = current.left[head]
            let sampleR = current.right[head]
            leftOut[i] = shaped(XORMath.dequantize(sampleL, bits: bits), gain: level)
            rightOut[i] = shaped(XORMath.dequantize(sampleR, bits: bits), gain: level)
            if let traceNow, let traceDelayed, head < traceNow.count, head < traceDelayed.count {
                ringA[ringWrite] = XORMath.dequantize(traceNow[head], bits: bits)
                ringB[ringWrite] = XORMath.dequantize(traceDelayed[head], bits: bits)
                lastA = Int32(traceNow[head])
                lastB = Int32(traceDelayed[head])
            } else {
                let side = current.plan.leftSide(head)
                ringA[ringWrite] = side.wave
                ringB[ringWrite] = side.other
                lastA = side.waveInt
                lastB = side.otherInt
            }
            ringX[ringWrite] = XORMath.dequantize(sampleL, bits: bits)
            lastX = Int32(sampleL)
            ringWrite += 1
            if ringWrite == ringCount { ringWrite = 0 }
            if ringFilled < ringCount { ringFilled += 1 }
            head += 1
        }
        playhead = head >= total ? 0 : head
        return noErr
    }

    private func shaped(_ x: Float, gain: Float) -> Float {
        let y = x * gain
        if !y.isFinite { return 0 }
        return min(1, max(-1, y))
    }
}

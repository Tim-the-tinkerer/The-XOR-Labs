import Foundation

/// Which ear hears the delayed XOR.
enum EarMode: String, Equatable, CaseIterable, Identifiable {
    case both
    case leftOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Both"
        case .leftOnly: return "Left only"
        }
    }
}

/// One rendered delay stage, before volume. Volume stays in the player.
struct DelayStep {
    var mixed: Int32
    var q: Int32
    var delayed: Int32
    var delaySamples: Int
    var milliseconds: Double
}

/// The delay the voice will use. Sweep is ignored while the three delays are stacked.
struct DelaySettings {
    var delayMilliseconds: Double
    var stacked: Bool
    var bits: Int
    var sweepHz: Double
    var sweepDepthMilliseconds: Double

    init(_ job: Job) {
        delayMilliseconds = min(AppInfo.maxDelayMilliseconds, max(0, job.delayMs))
        stacked = job.stacked
        bits = job.clampedBits
        if job.stacked {
            sweepHz = 0
            sweepDepthMilliseconds = 0
        } else {
            let hz = job.sweepHz.isFinite ? job.sweepHz : 0
            let depth = job.sweepDepth.isFinite ? job.sweepDepth : 0
            sweepHz = min(AppInfo.maxSweepHz, max(0, hz))
            sweepDepthMilliseconds = min(AppInfo.maxSweepDepthMilliseconds, max(0, depth))
        }
    }
}

/// Three delay rings. A single delay uses the first. Stack uses all three, in order.
///
/// Empty history XORs with 0, so the first `delay` samples pass through.
/// Delay 0 XORs a sample with itself and is silence. The delay is a whole
/// number of samples. There is nothing to put between two integers.
final class XORVoice {
    static let capacity = 131_072

    private var data: [[Int32]]
    private var write: [Int]
    private var held: [Int]
    private var sweepPhase = 0.0

    init() {
        data = (0..<3).map { _ in [Int32](repeating: 0, count: XORVoice.capacity) }
        write = [0, 0, 0]
        held = [0, 0, 0]
    }

    func step(quantized: Int32, sampleRate: Double, settings: DelaySettings) -> DelayStep {
        let bits = settings.bits
        let plan = planDelays(sampleRate: sampleRate, settings: settings)
        var s = quantized
        var lastQ = s
        var lastD: Int32 = 0
        var lastY = s
        var lastSamples = plan.delays.first ?? 0
        for stage in 0..<plan.delays.count {
            let requested = plan.delays[stage]
            let d = min(max(requested, 0), XORVoice.capacity - 1)
            let delayed: Int32
            if d <= 0 || held[stage] < d {
                delayed = 0
            } else {
                delayed = read(stage, samplesAgo: d)
            }
            push(stage, s)
            let y: Int32 = d <= 0 ? 0 : XORMath.xorBits(s, delayed, bits: bits)
            lastQ = s
            lastD = d <= 0 ? s : delayed
            lastY = y
            lastSamples = d
            s = y
        }
        return DelayStep(
            mixed: lastY,
            q: lastQ,
            delayed: lastD,
            delaySamples: lastSamples,
            milliseconds: plan.milliseconds
        )
    }

    /// Delays for this sample. Sweep phase advances once per call.
    private func planDelays(sampleRate: Double, settings: DelaySettings) -> (delays: [Int], milliseconds: Double) {
        if settings.stacked {
            let delays = AppInfo.stackMilliseconds.map {
                XORMath.delaySamples(milliseconds: $0, sampleRate: sampleRate)
            }
            return (delays, AppInfo.stackMilliseconds.last ?? 50)
        }
        let extra = sweepOffset(sampleRate: sampleRate, settings: settings, advance: true)
        let ms = min(AppInfo.maxDelayMilliseconds, max(0, settings.delayMilliseconds + extra))
        return ([XORMath.delaySamples(milliseconds: ms, sampleRate: sampleRate)], ms)
    }

    private func sweepOffset(sampleRate: Double, settings: DelaySettings, advance: Bool) -> Double {
        let depth = settings.sweepDepthMilliseconds
        let rate = settings.sweepHz
        guard !settings.stacked, depth > 0, rate > 0, sampleRate > 0 else { return 0 }
        let offset = sin(sweepPhase) * depth
        if advance {
            sweepPhase += 2.0 * Double.pi * rate / sampleRate
            if sweepPhase > 2.0 * Double.pi { sweepPhase -= 2.0 * Double.pi }
        }
        return offset
    }

    private func read(_ stage: Int, samplesAgo: Int) -> Int32 {
        let d = min(max(samplesAgo, 1), XORVoice.capacity - 1)
        var i = write[stage] - d
        if i < 0 { i += XORVoice.capacity }
        return data[stage][i]
    }

    private func push(_ stage: Int, _ value: Int32) {
        data[stage][write[stage]] = value
        write[stage] += 1
        if write[stage] == XORVoice.capacity { write[stage] = 0 }
        if held[stage] < Int.max { held[stage] += 1 }
    }
}

extension XORMath {
    static func delaySamples(milliseconds: Double, sampleRate: Double) -> Int {
        guard milliseconds.isFinite, sampleRate > 0 else { return 0 }
        let ms = min(AppInfo.maxDelayMilliseconds, max(0, milliseconds))
        return Int((ms * sampleRate / 1000.0).rounded())
    }

    /// Whole cycles of `frequency` inside the delay, when the delay lands on one.
    static func wholeCycles(frequency: Double, milliseconds: Double) -> Int? {
        guard frequency.isFinite, milliseconds.isFinite, frequency > 0, milliseconds > 0 else { return nil }
        let cycles = frequency * milliseconds / 1000.0
        let nearest = cycles.rounded()
        guard nearest >= 1, abs(cycles - nearest) < 0.02 else { return nil }
        return Int(nearest)
    }

    static func sine(index: Int, frequency: Double, sampleRate: Double, amplitude: Float = BuiltIn.amplitude) -> Float {
        guard sampleRate > 0, frequency.isFinite else { return 0 }
        let t = Double(index) / sampleRate
        return amplitude * Float(sin(2.0 * Double.pi * frequency * t))
    }

    /// Mix of the file's two channels. 0 returns `left`. 1 returns `right`.
    static func channelBlend(_ left: Float, _ right: Float, amount: Float) -> Float {
        let mix = amount.isFinite ? min(1, max(0, amount)) : 0
        let l = left.isFinite ? left : 0
        let r = right.isFinite ? right : 0
        if mix <= 0 { return l }
        if mix >= 1 { return r }
        let y = l * (1 - mix) + r * mix
        return y.isFinite ? y : 0
    }

    static func renderDelay(_ job: Job) -> Take {
        var job = job
        job.delayMs = min(AppInfo.maxDelayMilliseconds, max(0, job.delayMs.isFinite ? job.delayMs : 0))
        job.blend = min(1, max(0, job.blend.isFinite ? job.blend : 0))
        if job.demo { job.blendEnabled = false }
        let bits = job.clampedBits
        guard let clip = job.a, clip.frames > 0, clip.sampleRate > 0 else {
            return Take.idle(caption: "Drop an audio file.", bits: bits, demo: job.demo)
        }

        let n = clip.frames
        let rate = clip.sampleRate
        let settings = DelaySettings(job)
        let blendOn = job.blendEnabled
        let voiceL = XORVoice()
        let voiceR = XORVoice()
        let sameInput = blendOn || clip.isMono
        var left = [Int16](repeating: 0, count: n)
        var right = [Int16](repeating: 0, count: n)
        var traceNow = [Int16](repeating: 0, count: n)
        var traceDelayed = [Int16](repeating: 0, count: n)

        let buckets = min(2400, n)
        var aLo = [Float](repeating: 0, count: buckets)
        var aHi = [Float](repeating: 0, count: buckets)
        var bLo = [Float](repeating: 0, count: buckets)
        var bHi = [Float](repeating: 0, count: buckets)
        var xLo = [Float](repeating: 0, count: buckets)
        var xHi = [Float](repeating: 0, count: buckets)
        var seen = [Bool](repeating: false, count: buckets)
        var bestAbs = Int32(-1)
        var bestA: Int32 = 0
        var bestB: Int32 = 0
        var bestX: Int32 = 0

        for i in 0..<n {
            let qL = blendedOrStored(clip, channel: 0, index: i, bits: bits, blendOn: blendOn, amount: job.blend)
            let qR = sameInput
                ? qL
                : blendedOrStored(clip, channel: 1, index: i, bits: bits, blendOn: false, amount: 0)
            let stepL = voiceL.step(quantized: qL, sampleRate: rate, settings: settings)
            let yL = pack(stepL.mixed)
            let yR: Int16
            if job.ears == .leftOnly {
                yR = pack(qR)
            } else if sameInput {
                yR = yL
            } else {
                let stepR = voiceR.step(quantized: qR, sampleRate: rate, settings: settings)
                yR = pack(stepR.mixed)
            }
            left[i] = yL
            right[i] = yR
            traceNow[i] = pack(stepL.q)
            traceDelayed[i] = pack(stepL.delayed)

            let drawnNow = dequantize(traceNow[i], bits: bits)
            let drawnDelay = dequantize(traceDelayed[i], bits: bits)
            let drawnX = dequantize(yL, bits: bits)
            let bucket = i * buckets / n
            if !seen[bucket] {
                seen[bucket] = true
                aLo[bucket] = drawnNow
                aHi[bucket] = drawnNow
                bLo[bucket] = drawnDelay
                bHi[bucket] = drawnDelay
                xLo[bucket] = drawnX
                xHi[bucket] = drawnX
            } else {
                aLo[bucket] = min(aLo[bucket], drawnNow)
                aHi[bucket] = max(aHi[bucket], drawnNow)
                bLo[bucket] = min(bLo[bucket], drawnDelay)
                bHi[bucket] = max(bHi[bucket], drawnDelay)
                xLo[bucket] = min(xLo[bucket], drawnX)
                xHi[bucket] = max(xHi[bucket], drawnX)
            }
            let magnitude = abs(Int32(yL))
            if magnitude > bestAbs {
                bestAbs = magnitude
                bestA = Int32(traceNow[i])
                bestB = Int32(traceDelayed[i])
                bestX = Int32(yL)
            }
        }

        let settleMs = job.stacked ? AppInfo.stackSettleMilliseconds : job.delayMs
        let settle = min(n, delaySamples(milliseconds: settleMs, sampleRate: rate))
        let leftTail = settle < n ? Array(left[settle...]) : left
        let rightTail = settle < n ? Array(right[settle...]) : right
        let leftSilent = isSilent(leftTail, bits: bits)
        let rightSilent = isSilent(rightTail, bits: bits)
        let center = delaySamples(milliseconds: job.delayMs, sampleRate: rate)
        let caption = Caption.delay(
            job,
            leftSilent: leftSilent,
            rightSilent: rightSilent,
            rate: rate,
            delaySamples: center
        )
        let picture = WavePicture(
            aLo: aLo,
            aHi: aHi,
            bLo: bLo,
            bHi: bHi,
            xLo: xLo,
            xHi: xHi,
            qA: bestA,
            qB: bestB,
            qX: bestX,
            bits: bits,
            silent: leftSilent,
            peaked: n > buckets
        )
        return Take(
            left: left,
            right: right,
            plan: Plan.empty(bits: bits),
            sampleRate: rate,
            bits: bits,
            picture: picture,
            caption: caption.text,
            erased: caption.erased,
            demo: job.demo,
            traceNow: traceNow,
            traceDelayed: traceDelayed
        )
    }

    /// Blend mixes the waveforms, then quantizes. Otherwise a 16-bit file keeps its integers.
    private static func blendedOrStored(
        _ clip: Clip,
        channel: Int,
        index: Int,
        bits: Int,
        blendOn: Bool,
        amount: Float
    ) -> Int32 {
        if blendOn {
            let l = index < clip.left.count ? finite(clip.left[index]) : 0
            let r = index < clip.right.count ? finite(clip.right[index]) : 0
            return quantize(channelBlend(l, r, amount: amount), bits: bits)
        }
        let useLeft = clip.isMono || channel == 0
        let floats = useLeft ? clip.left : clip.right
        let pcm = useLeft ? clip.pcmLeft : clip.pcmRight
        guard index >= 0, index < floats.count else { return 0 }
        if bits == 16, let pcm, index < pcm.count {
            return Int32(pcm[index])
        }
        return quantize(floats[index], bits: bits)
    }
}

extension Caption {
    static func millisecondsText(_ ms: Double) -> String {
        guard ms.isFinite else { return "0 ms" }
        if abs(ms - ms.rounded()) < 0.05 {
            return "\(Int(ms.rounded())) ms"
        }
        return String(format: "%.1f ms", ms)
    }

    static func frequencyText(_ hz: Double) -> String {
        guard hz.isFinite else { return "0 Hz" }
        if abs(hz - hz.rounded()) < 0.05 {
            return "\(Int(hz.rounded())) Hz"
        }
        return String(format: "%.1f Hz", hz)
    }

    static func delay(
        _ job: Job,
        leftSilent: Bool,
        rightSilent: Bool,
        rate: Double,
        delaySamples: Int
    ) -> (text: String, erased: Bool) {
        let sweeping = !job.stacked && job.sweepHz > 0 && job.sweepDepth > 0
        if !job.stacked && job.delayMs <= 0 && !sweeping {
            return ("0 ms XORs each sample with itself. That is silence.", true)
        }
        if leftSilent && job.stacked && job.demo {
            let hz = frequencyText(job.toneHz)
            return ("The stack erased this \(hz) tone. A stage lined up with the pitch it was given.", true)
        }
        if leftSilent && job.demo && !job.stacked && !sweeping {
            if let cycles = XORMath.wholeCycles(frequency: job.toneHz, milliseconds: job.delayMs) {
                let ms = millisecondsText(job.delayMs)
                let hz = frequencyText(job.toneHz)
                return ("\(ms) is \(cycles) cycles of \(hz). The copies agree, so XOR erases them.", true)
            }
            return ("The copies agree, so XOR erases them.", true)
        }
        if leftSilent && !job.demo {
            if job.ears == .leftOnly && !rightSilent {
                return ("The copies agree, so the left channel is erased. The right channel stays as it was.", true)
            }
            return ("The copies agree, so XOR erases them.", true)
        }

        var sentences: [String] = []
        if job.stacked {
            sentences.append("10 ms, then 20 ms, then 50 ms. Each stage XORs the previous result with a delayed copy of itself.")
        } else if sweeping {
            let ms = millisecondsText(job.delayMs)
            sentences.append("The delay moves around \(ms) across the file. It jumps by whole samples.")
        } else {
            let ms = millisecondsText(job.delayMs)
            let count = max(0, delaySamples)
            let unit = count == 1 ? "sample" : "samples"
            sentences.append("\(ms) · \(count) \(unit) at \(XORMath.rateLabel(rate)).")
        }
        if job.ears == .leftOnly {
            sentences.append("The left channel is XORed. The right channel stays as it was.")
        } else if job.blendEnabled {
            sentences.append(blendPhrase(job.blend))
        } else if job.demo && !job.stacked && !sweeping {
            sentences.append("Disagreeing bits stay.")
        } else if !job.stacked && !sweeping {
            sentences.append("Each channel is XORed with its own delay.")
        }
        if job.clampedBits == 8 {
            sentences.append("8-bit is the same XOR on a coarser integer.")
        }
        return (sentences.joined(separator: " "), false)
    }

    private static func blendPhrase(_ amount: Float) -> String {
        if amount <= 0.001 { return "The left channel is used on both sides, then the XOR." }
        if amount >= 0.999 { return "The right channel is used on both sides, then the XOR." }
        return "The left and right are blended before the XOR."
    }
}

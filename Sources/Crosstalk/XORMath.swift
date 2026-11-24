import Foundation

/// What is being XORed.
enum ListenMode: String, Equatable, CaseIterable, Identifiable {
    case channels
    case waveform
    case files
    case delay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .channels: return "Channels"
        case .waveform: return "Waveform"
        case .files: return "Files"
        case .delay: return "Delay"
        }
    }
}

/// One file, folded against itself.
enum WaveFold: String, Equatable, CaseIterable, Identifiable {
    case reverse
    case halves

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reverse: return "Reverse"
        case .halves: return "Halves"
        }
    }
}

/// Which loaded file a mode hears. Files ignores this and XORs the two recordings.
enum SourcePick: String, Equatable, CaseIterable, Identifiable {
    case first
    case second
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .first: return "First"
        case .second: return "Second"
        case .both: return "Both"
        }
    }
}

/// How two files of different lengths share a timeline.
enum Span: String, Equatable, CaseIterable, Identifiable {
    case shorter
    case longer
    case loop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shorter: return "Shorter"
        case .longer: return "Longer"
        case .loop: return "Loop"
        }
    }
}

/// One loaded recording. `pcmLeft` is set for 16-bit integer WAV, and those
/// integers are what the XOR uses. Anything else is quantized from `left`.
struct Clip {
    var name: String
    var url: URL?
    var left: [Float]
    var right: [Float]
    var pcmLeft: [Int16]?
    var pcmRight: [Int16]?
    var sampleRate: Double
    var channelCount: Int
    var truncated: Bool

    var frames: Int { left.count }

    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(left.count) / sampleRate
    }

    var isMono: Bool { channelCount < 2 }
}

struct Job {
    var mode: ListenMode = .channels
    var fold: WaveFold = .reverse
    var span: Span = .shorter
    var bits: Int = 16
    var slipMs: Double = 0
    var delayMs: Double = 10
    var stacked: Bool = false
    var ears: EarMode = .both
    var sweepHz: Double = 0
    var sweepDepth: Double = 0
    var blendEnabled: Bool = false
    var blend: Float = 0.5
    var toneHz: Double = 220
    var a: Clip?
    var b: Clip?
    var demo: Bool = false

    var clampedBits: Int { bits == 8 ? 8 : 16 }
}

struct WavePicture: Equatable {
    var aLo: [Float]
    var aHi: [Float]
    var bLo: [Float]
    var bHi: [Float]
    var xLo: [Float]
    var xHi: [Float]
    var qA: Int32
    var qB: Int32
    var qX: Int32
    var bits: Int
    var silent: Bool
    var peaked: Bool

    static let empty = WavePicture(
        aLo: [0], aHi: [0], bLo: [0], bHi: [0], xLo: [0], xHi: [0],
        qA: 0, qB: 0, qX: 0, bits: 16, silent: true, peaked: false
    )
}

/// The XOR, as integers. Playback turns these into sound. A 16-bit export writes them unchanged.
final class Take {
    let left: [Int16]
    let right: [Int16]
    let plan: Plan
    let sampleRate: Double
    let bits: Int
    let picture: WavePicture
    let caption: String
    let erased: Bool
    let demo: Bool
    /// The two integers that met on the left channel. The scope reads these while audio plays.
    let traceNow: [Int16]?
    let traceDelayed: [Int16]?

    var count: Int { left.count }

    init(
        left: [Int16],
        right: [Int16],
        plan: Plan,
        sampleRate: Double,
        bits: Int,
        picture: WavePicture,
        caption: String,
        erased: Bool,
        demo: Bool,
        traceNow: [Int16]? = nil,
        traceDelayed: [Int16]? = nil
    ) {
        self.left = left
        self.right = right
        self.plan = plan
        self.sampleRate = sampleRate
        self.bits = bits
        self.picture = picture
        self.caption = caption
        self.erased = erased
        self.demo = demo
        self.traceNow = traceNow
        self.traceDelayed = traceDelayed
    }

    static func idle(caption: String, bits: Int, demo: Bool) -> Take {
        var picture = WavePicture.empty
        picture.bits = bits
        return Take(
            left: [],
            right: [],
            plan: Plan.empty(bits: bits),
            sampleRate: AppInfo.renderRate,
            bits: bits,
            picture: picture,
            caption: caption,
            erased: false,
            demo: demo
        )
    }
}

/// The two values that meet at one sample, plus the floats the scope draws.
struct Side {
    var wave: Float
    var other: Float
    var waveInt: Int32
    var otherInt: Int32
}

/// Immutable index math for one render. The audio thread reads it and does not copy the samples out.
final class Plan {
    let count: Int
    let sampleRate: Double
    let bits: Int
    let mode: ListenMode
    let fold: WaveFold
    let span: Span
    let origin: Int
    let slip: Int
    let aCount: Int
    let bCount: Int
    let aChannels: Int
    let bChannels: Int
    let ratesMatch: Bool
    let aRate: Double
    let bRate: Double

    private let aL: [Float]
    private let aR: [Float]
    private let bL: [Float]
    private let bR: [Float]
    private let aPcmL: [Int16]?
    private let aPcmR: [Int16]?
    private let bPcmL: [Int16]?
    private let bPcmR: [Int16]?

    init(
        count: Int,
        sampleRate: Double,
        bits: Int,
        mode: ListenMode,
        fold: WaveFold,
        span: Span,
        origin: Int,
        slip: Int,
        aCount: Int,
        bCount: Int,
        aChannels: Int,
        bChannels: Int,
        ratesMatch: Bool,
        aRate: Double,
        bRate: Double,
        aL: [Float],
        aR: [Float],
        bL: [Float],
        bR: [Float],
        aPcmL: [Int16]?,
        aPcmR: [Int16]?,
        bPcmL: [Int16]?,
        bPcmR: [Int16]?
    ) {
        self.count = count
        self.sampleRate = sampleRate
        self.bits = bits
        self.mode = mode
        self.fold = fold
        self.span = span
        self.origin = origin
        self.slip = slip
        self.aCount = aCount
        self.bCount = bCount
        self.aChannels = aChannels
        self.bChannels = bChannels
        self.ratesMatch = ratesMatch
        self.aRate = aRate
        self.bRate = bRate
        self.aL = aL
        self.aR = aR
        self.bL = bL
        self.bR = bR
        self.aPcmL = aPcmL
        self.aPcmR = aPcmR
        self.bPcmL = bPcmL
        self.bPcmR = bPcmR
    }

    static func empty(bits: Int) -> Plan {
        Plan(
            count: 0,
            sampleRate: AppInfo.renderRate,
            bits: bits,
            mode: .channels,
            fold: .reverse,
            span: .shorter,
            origin: 0,
            slip: 0,
            aCount: 0,
            bCount: 0,
            aChannels: 1,
            bChannels: 1,
            ratesMatch: true,
            aRate: AppInfo.renderRate,
            bRate: AppInfo.renderRate,
            aL: [],
            aR: [],
            bL: [],
            bR: [],
            aPcmL: nil,
            aPcmR: nil,
            bPcmL: nil,
            bPcmR: nil
        )
    }

    func leftSide(_ i: Int) -> Side {
        switch mode {
        case .channels:
            return Side(
                wave: stored(aL, aPcmL, i),
                other: stored(channelFloats(1, ofA: true), channelPCM(1, ofA: true), i),
                waveInt: storedInt(aL, aPcmL, i),
                otherInt: storedInt(channelFloats(1, ofA: true), channelPCM(1, ofA: true), i)
            )
        case .waveform:
            return folded(i, channel: 0)
        case .files:
            return filed(i, channel: 0)
        case .delay:
            return Side(wave: 0, other: 0, waveInt: 0, otherInt: 0)
        }
    }

    func rightSide(_ i: Int) -> Side {
        switch mode {
        case .channels:
            return leftSide(i)
        case .waveform:
            return folded(i, channel: aChannels == 1 ? 0 : 1)
        case .files:
            return filed(i, channel: 1)
        case .delay:
            return leftSide(i)
        }
    }

    private func folded(_ i: Int, channel: Int) -> Side {
        let n = aCount
        let floats = channel == 0 ? aL : channelFloats(channel, ofA: true)
        let pcm = channel == 0 ? aPcmL : channelPCM(channel, ofA: true)
        let wave = stored(floats, pcm, i)
        let waveInt = storedInt(floats, pcm, i)
        let partner: Int?
        switch fold {
        case .reverse:
            partner = n > 0 ? (n - 1 - i) : nil
        case .halves:
            let half = (n + 1) / 2
            let j = i + half
            partner = j < n ? j : nil
        }
        guard let partner else {
            return Side(wave: wave, other: 0, waveInt: waveInt, otherInt: 0)
        }
        return Side(
            wave: wave,
            other: stored(floats, pcm, partner),
            waveInt: waveInt,
            otherInt: storedInt(floats, pcm, partner)
        )
    }

    private func filed(_ i: Int, channel: Int) -> Side {
        let timeline = span == .shorter ? origin + i : i
        let aIndex = indexed(timeline, count: aCount, loop: span == .loop)
        let bRaw = timeline - slip
        let bIndex = indexed(bRaw, count: bCount, loop: span == .loop)
        let aChannel = aChannels == 1 ? 0 : channel
        let bChannel = bChannels == 1 ? 0 : channel
        let aFloats = aChannel == 0 ? aL : aR
        let aPCM = aChannel == 0 ? aPcmL : aPcmR
        let bFloats = bChannel == 0 ? bL : bR
        if let aIndex {
            let waveInt = storedInt(aFloats, aPCM, aIndex)
            let wave = stored(aFloats, aPCM, aIndex)
            if let bIndex {
                let other = resampled(bFloats, bChannel, bIndex)
                return Side(wave: wave, other: other.0, waveInt: waveInt, otherInt: other.1)
            }
            return Side(wave: wave, other: 0, waveInt: waveInt, otherInt: 0)
        }
        if let bIndex {
            let other = resampled(bFloats, bChannel, bIndex)
            return Side(wave: 0, other: other.0, waveInt: 0, otherInt: other.1)
        }
        return Side(wave: 0, other: 0, waveInt: 0, otherInt: 0)
    }

    private func indexed(_ i: Int, count: Int, loop: Bool) -> Int? {
        guard count > 0 else { return nil }
        if loop {
            var m = i % count
            if m < 0 { m += count }
            return m
        }
        if i < 0 || i >= count { return nil }
        return i
    }

    private func channelFloats(_ channel: Int, ofA: Bool) -> [Float] {
        if ofA { return channel == 0 || aChannels == 1 ? aL : aR }
        return channel == 0 || bChannels == 1 ? bL : bR
    }

    private func channelPCM(_ channel: Int, ofA: Bool) -> [Int16]? {
        if ofA { return channel == 0 || aChannels == 1 ? aPcmL : aPcmR }
        return channel == 0 || bChannels == 1 ? bPcmL : bPcmR
    }

    private func stored(_ floats: [Float], _ pcm: [Int16]?, _ index: Int) -> Float {
        guard index >= 0, index < floats.count else { return 0 }
        if bits == 16, let pcm, index < pcm.count {
            return XORMath.draw(pcm[index])
        }
        return XORMath.finite(floats[index])
    }

    private func storedInt(_ floats: [Float], _ pcm: [Int16]?, _ index: Int) -> Int32 {
        guard index >= 0, index < floats.count else { return 0 }
        if bits == 16, let pcm, index < pcm.count {
            return Int32(pcm[index])
        }
        return XORMath.quantize(floats[index], bits: bits)
    }

    /// B at a resampled index. Matching rates read the integer. Any other rate is linear, then quantized.
    private func resampled(_ floats: [Float], _ channel: Int, _ index: Int) -> (Float, Int32) {
        guard bCount > 0, index >= 0, index < bCount, !floats.isEmpty else { return (0, 0) }
        if ratesMatch {
            let pcm = channel == 0 || bChannels == 1 ? bPcmL : bPcmR
            return (stored(floats, pcm, index), storedInt(floats, pcm, index))
        }
        let position = XORMath.sourcePosition(
            index: index,
            frames: floats.count,
            resampled: bCount,
            fromRate: bRate,
            toRate: aRate
        )
        let x = XORMath.readLinear(floats, position)
        return (x, XORMath.quantize(x, bits: bits))
    }
}

enum XORMath {
    /// Positive peak of a signed integer at this width. Full scale is 32767 or 127, never the missing negative step.
    static func quantize(_ x: Float, bits: Int) -> Int32 {
        let width = bits == 8 ? 8 : 16
        if !x.isFinite { return 0 }
        let peak = (1 << (width - 1)) - 1
        let minNeg = -peak - 1
        let clamped = min(Float(1), max(Float(-1), x))
        let scaled = (Double(clamped) * Double(peak)).rounded()
        let v = Int(scaled)
        if v >= peak { return Int32(peak) }
        if v <= minNeg { return Int32(minNeg) }
        return Int32(v)
    }

    /// XOR at `bits` width, then sign-extend back to a signed integer.
    static func xorBits(_ a: Int32, _ b: Int32, bits: Int) -> Int32 {
        let width = bits == 8 ? 8 : 16
        let mask = (1 << width) - 1
        var y = (Int(a) & mask) ^ (Int(b) & mask)
        if y & (1 << (width - 1)) != 0 {
            y -= 1 << width
        }
        return Int32(y)
    }

    static func pack(_ v: Int32) -> Int16 {
        Int16(truncatingIfNeeded: v)
    }

    static func dequantize(_ v: Int16, bits: Int) -> Float {
        let peak: Float = bits == 8 ? 127 : 32767
        let y = Float(v) / peak
        if !y.isFinite { return 0 }
        return min(1, max(-1, y))
    }

    /// Scope height for a stored integer. −32768 is one step under −1 and is drawn on the rail.
    static func draw(_ v: Int16) -> Float {
        let y = Float(v) / 32767
        if !y.isFinite { return 0 }
        return min(1, max(-1, y))
    }

    static func finite(_ x: Float) -> Float {
        x.isFinite ? x : 0
    }

    /// Exact agreement is silence. A single surviving bit still counts.
    static func isSilent(_ samples: [Int16], bits: Int) -> Bool {
        for v in samples where v != 0 { return false }
        return true
    }

    static func resampledCount(frames: Int, fromRate: Double, toRate: Double) -> Int {
        guard frames > 0, fromRate > 0, toRate > 0 else { return 0 }
        if abs(fromRate - toRate) < 0.5 { return frames }
        let span = Double(frames - 1) * toRate / fromRate
        return max(1, Int(span.rounded()) + 1)
    }

    /// Index 0 is the first sample. The last resampled index is the last sample.
    static func sourcePosition(index: Int, frames: Int, resampled: Int, fromRate: Double, toRate: Double) -> Double {
        if frames <= 1 || resampled <= 1 { return 0 }
        if abs(fromRate - toRate) < 0.5 { return Double(index) }
        return Double(index) * Double(frames - 1) / Double(resampled - 1)
    }

    static func readLinear(_ data: [Float], _ position: Double) -> Float {
        let n = data.count
        guard n > 0, position.isFinite else { return 0 }
        if position <= 0 { return finite(data[0]) }
        if position >= Double(n - 1) { return finite(data[n - 1]) }
        let i0 = Int(position)
        let i1 = min(i0 + 1, n - 1)
        let frac = Float(position - Double(i0))
        let a = finite(data[i0])
        let b = finite(data[i1])
        if frac == 0 || i0 == i1 { return a }
        return finite(a + (b - a) * frac)
    }

    static func slipSamples(milliseconds: Double, sampleRate: Double) -> Int {
        guard milliseconds.isFinite, sampleRate > 0 else { return 0 }
        let ms = min(AppInfo.maxSlipMilliseconds, max(-AppInfo.maxSlipMilliseconds, milliseconds))
        return Int((ms * sampleRate / 1000).rounded())
    }

    static func render(_ job: Job) -> Take {
        if job.mode == .delay {
            return renderDelay(job)
        }
        let bits = job.clampedBits
        guard let plan = makePlan(job) else {
            return Take.idle(caption: Caption.waiting(job), bits: bits, demo: job.demo)
        }
        if plan.count <= 0 {
            return Take.idle(caption: "That slip leaves no overlap.", bits: bits, demo: job.demo)
        }

        var left = [Int16](repeating: 0, count: plan.count)
        var right = [Int16](repeating: 0, count: plan.count)
        let buckets = min(2400, plan.count)
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

        for i in 0..<plan.count {
            let side = plan.leftSide(i)
            let yL = pack(xorBits(side.waveInt, side.otherInt, bits: bits))
            let yR: Int16
            if plan.mode == .channels {
                yR = yL
            } else {
                let other = plan.rightSide(i)
                yR = pack(xorBits(other.waveInt, other.otherInt, bits: bits))
            }
            left[i] = yL
            right[i] = yR

            let drawn = dequantize(yL, bits: bits)
            let bucket = i * buckets / plan.count
            if !seen[bucket] {
                seen[bucket] = true
                aLo[bucket] = side.wave
                aHi[bucket] = side.wave
                bLo[bucket] = side.other
                bHi[bucket] = side.other
                xLo[bucket] = drawn
                xHi[bucket] = drawn
            } else {
                aLo[bucket] = min(aLo[bucket], side.wave)
                aHi[bucket] = max(aHi[bucket], side.wave)
                bLo[bucket] = min(bLo[bucket], side.other)
                bHi[bucket] = max(bHi[bucket], side.other)
                xLo[bucket] = min(xLo[bucket], drawn)
                xHi[bucket] = max(xHi[bucket], drawn)
            }
            let magnitude = abs(Int32(yL))
            if magnitude > bestAbs {
                bestAbs = magnitude
                bestA = side.waveInt
                bestB = side.otherInt
                bestX = Int32(yL)
            }
        }

        let silent = isSilent(left, bits: bits) && isSilent(right, bits: bits)
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
            silent: silent,
            peaked: plan.count > buckets
        )
        let caption = Caption.line(job, frames: plan.count, silent: silent, rate: plan.sampleRate)
        return Take(
            left: left,
            right: right,
            plan: plan,
            sampleRate: plan.sampleRate,
            bits: bits,
            picture: picture,
            caption: caption.text,
            erased: caption.erased,
            demo: job.demo
        )
    }

    /// Run one mode on each file, then XOR those integer results. The shorter result sets the length.
    /// Matching rates XOR the stored integers. A different rate resamples the second result.
    static func combine(_ first: Take, _ second: Take, mode: ListenMode) -> Take {
        let bits = first.bits == 8 ? 8 : 16
        let rate = first.sampleRate > 0 ? first.sampleRate : second.sampleRate
        if first.count == 0 {
            return Take.idle(caption: first.caption, bits: bits, demo: first.demo)
        }
        if second.count == 0 {
            return Take.idle(caption: second.caption, bits: bits, demo: second.demo)
        }
        let ratesDiffer = abs(first.sampleRate - second.sampleRate) >= 0.5
        let bLeft = ratesDiffer
            ? alignIntegers(second.left, fromRate: second.sampleRate, toRate: rate, bits: bits)
            : second.left
        let bRight = ratesDiffer
            ? alignIntegers(second.right, fromRate: second.sampleRate, toRate: rate, bits: bits)
            : second.right
        let n = min(first.left.count, first.right.count, bLeft.count, bRight.count)
        if n <= 0 {
            return Take.idle(caption: "The shorter one sets the length.", bits: bits, demo: first.demo && second.demo)
        }
        var left = [Int16](repeating: 0, count: n)
        var right = [Int16](repeating: 0, count: n)
        var traceA = [Int16](repeating: 0, count: n)
        var traceB = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            traceA[i] = first.left[i]
            traceB[i] = bLeft[i]
            left[i] = pack(xorBits(Int32(first.left[i]), Int32(bLeft[i]), bits: bits))
            right[i] = pack(xorBits(Int32(first.right[i]), Int32(bRight[i]), bits: bits))
        }
        let silent = isSilent(left, bits: bits) && isSilent(right, bits: bits)
        let (text, erased) = combineCaption(mode: mode, bits: bits, ratesDiffer: ratesDiffer, silent: silent, rate: rate)
        return Take(
            left: left,
            right: right,
            plan: Plan.empty(bits: bits),
            sampleRate: rate,
            bits: bits,
            picture: envelope(traceA: traceA, traceB: traceB, xor: left, bits: bits, silent: silent),
            caption: text,
            erased: erased,
            demo: first.demo && second.demo,
            traceNow: traceA,
            traceDelayed: traceB
        )
    }

    /// Linear resample of already-rendered integers. The new values are quantized again.
    static func alignIntegers(_ samples: [Int16], fromRate: Double, toRate: Double, bits: Int) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        if abs(fromRate - toRate) < 0.5 { return samples }
        let width = bits == 8 ? 8 : 16
        let count = resampledCount(frames: samples.count, fromRate: fromRate, toRate: toRate)
        guard count > 0 else { return [] }
        let floats = samples.map { dequantize($0, bits: width) }
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let position = sourcePosition(
                index: i,
                frames: samples.count,
                resampled: count,
                fromRate: fromRate,
                toRate: toRate
            )
            out[i] = pack(quantize(readLinear(floats, position), bits: width))
        }
        return out
    }

    private static func combineCaption(
        mode: ListenMode,
        bits: Int,
        ratesDiffer: Bool,
        silent: Bool,
        rate: Double
    ) -> (String, Bool) {
        if silent {
            return ("These samples agree, so XOR erases them.", true)
        }
        let lead: String
        switch mode {
        case .channels:
            lead = "Channels on each file, then those results are XORed."
        case .waveform:
            lead = "Each file is folded, then the folds are XORed."
        case .delay:
            lead = "Each file is delayed, then the delays are XORed."
        case .files:
            lead = "The two results are XORed."
        }
        var sentences = [lead, "The shorter one sets the length."]
        if ratesDiffer {
            sentences.append("The second file is resampled to \(rateLabel(rate)). Those are new integers, so this pass will not reverse exactly.")
        } else if bits == 8 {
            sentences.append("8-bit is the same XOR on a coarser integer.")
        }
        return (sentences.joined(separator: " "), false)
    }

    private static func envelope(traceA: [Int16], traceB: [Int16], xor: [Int16], bits: Int, silent: Bool) -> WavePicture {
        let n = xor.count
        let buckets = min(2400, max(1, n))
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
            let wave = dequantize(traceA[i], bits: bits)
            let other = dequantize(traceB[i], bits: bits)
            let drawn = dequantize(xor[i], bits: bits)
            let bucket = min(buckets - 1, i * buckets / n)
            if !seen[bucket] {
                seen[bucket] = true
                aLo[bucket] = wave
                aHi[bucket] = wave
                bLo[bucket] = other
                bHi[bucket] = other
                xLo[bucket] = drawn
                xHi[bucket] = drawn
            } else {
                aLo[bucket] = min(aLo[bucket], wave)
                aHi[bucket] = max(aHi[bucket], wave)
                bLo[bucket] = min(bLo[bucket], other)
                bHi[bucket] = max(bHi[bucket], other)
                xLo[bucket] = min(xLo[bucket], drawn)
                xHi[bucket] = max(xHi[bucket], drawn)
            }
            let magnitude = abs(Int32(xor[i]))
            if magnitude > bestAbs {
                bestAbs = magnitude
                bestA = Int32(traceA[i])
                bestB = Int32(traceB[i])
                bestX = Int32(xor[i])
            }
        }
        return WavePicture(
            aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, xLo: xLo, xHi: xHi,
            qA: bestA, qB: bestB, qX: bestX, bits: bits, silent: silent, peaked: n > buckets
        )
    }

    static func makePlan(_ job: Job) -> Plan? {
        let bits = job.clampedBits
        switch job.mode {
        case .channels, .waveform:
            guard let a = job.a, a.frames > 0, a.sampleRate > 0 else { return nil }
            let count = job.mode == .waveform && job.fold == .halves ? (a.frames + 1) / 2 : a.frames
            return Plan(
                count: count,
                sampleRate: a.sampleRate,
                bits: bits,
                mode: job.mode,
                fold: job.fold,
                span: .shorter,
                origin: 0,
                slip: 0,
                aCount: a.frames,
                bCount: 0,
                aChannels: a.isMono ? 1 : 2,
                bChannels: 1,
                ratesMatch: true,
                aRate: a.sampleRate,
                bRate: a.sampleRate,
                aL: a.left,
                aR: a.right,
                bL: [],
                bR: [],
                aPcmL: a.pcmLeft,
                aPcmR: a.pcmRight,
                bPcmL: nil,
                bPcmR: nil
            )
        case .files:
            guard let a = job.a, let b = job.b, a.frames > 0, b.frames > 0, a.sampleRate > 0, b.sampleRate > 0 else {
                return nil
            }
            let match = abs(a.sampleRate - b.sampleRate) < 0.5
            let bCount = resampledCount(frames: b.frames, fromRate: b.sampleRate, toRate: a.sampleRate)
            let slip = slipSamples(milliseconds: job.slipMs, sampleRate: a.sampleRate)
            let origin: Int
            let count: Int
            switch job.span {
            case .shorter:
                origin = max(0, slip)
                let end = min(a.frames, slip + bCount)
                count = max(0, end - origin)
            case .longer:
                origin = 0
                count = max(a.frames, max(0, slip + bCount))
            case .loop:
                origin = 0
                count = max(a.frames, bCount)
            }
            return Plan(
                count: count,
                sampleRate: a.sampleRate,
                bits: bits,
                mode: .files,
                fold: job.fold,
                span: job.span,
                origin: origin,
                slip: slip,
                aCount: a.frames,
                bCount: bCount,
                aChannels: a.isMono ? 1 : 2,
                bChannels: b.isMono ? 1 : 2,
                ratesMatch: match,
                aRate: a.sampleRate,
                bRate: b.sampleRate,
                aL: a.left,
                aR: a.right,
                bL: b.left,
                bR: b.right,
                aPcmL: a.pcmLeft,
                aPcmR: a.pcmRight,
                bPcmL: b.pcmLeft,
                bPcmR: b.pcmRight
            )
        case .delay:
            return nil
        }
    }

    static func rateLabel(_ sampleRate: Double) -> String {
        if abs(sampleRate - 44_100) < 1 { return "44.1 kHz" }
        if abs(sampleRate - 48_000) < 1 { return "48 kHz" }
        if abs(sampleRate - 88_200) < 1 { return "88.2 kHz" }
        if abs(sampleRate - 96_000) < 1 { return "96 kHz" }
        if abs(sampleRate - 192_000) < 1 { return "192 kHz" }
        return String(format: "%.1f kHz", sampleRate / 1000)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        if seconds < 10 && abs(seconds - seconds.rounded()) > 0.05 {
            return String(format: "%.1f s", seconds)
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static let fact = "1000 XOR 2000 is 1080. Volume is playback only."
}

enum Caption {
    static func waiting(_ job: Job) -> String {
        if job.mode == .files {
            if job.a == nil && job.b != nil { return "Drop the first file." }
            return "Drop a second file. It is XORed with the first, sample by sample."
        }
        return "Drop an audio file."
    }

    static func line(_ job: Job, frames: Int, silent: Bool, rate: Double) -> (text: String, erased: Bool) {
        if frames <= 0 {
            return ("That slip leaves no overlap.", false)
        }
        switch job.mode {
        case .channels:
            return channels(job, silent: silent)
        case .waveform:
            return waveform(job, silent: silent)
        case .files:
            return files(job, frames: frames, silent: silent, rate: rate)
        case .delay:
            return delay(job, leftSilent: silent, rightSilent: silent, rate: rate, delaySamples: 0)
        }
    }

    private static func channels(_ job: Job, silent: Bool) -> (String, Bool) {
        if job.a?.isMono == true {
            return ("This file has one channel. Both sides are the same waveform, so XOR erases them.", true)
        }
        if silent {
            return ("The two channels agree, so XOR erases them.", true)
        }
        return ("Left XOR right. Both ears hear that.", false)
    }

    private static func waveform(_ job: Job, silent: Bool) -> (String, Bool) {
        switch job.fold {
        case .reverse:
            if silent {
                return ("The waveform agrees with its reverse, so XOR erases it.", true)
            }
            return ("Each sample is XORed with the one across from it. Doing this again is silence.", false)
        case .halves:
            if silent {
                return ("The two halves agree, so XOR erases them.", true)
            }
            if let n = job.a?.frames, n % 2 == 1 {
                return ("The first half is XORed with the second half. The middle sample has no partner, so it passes through.", false)
            }
            return ("The first half is XORed with the second half.", false)
        }
    }

    private static func files(_ job: Job, frames: Int, silent: Bool, rate: Double) -> (String, Bool) {
        if silent {
            return ("These samples agree, so XOR erases them.", true)
        }
        let names = "\(job.a?.name ?? "A") XOR \(job.b?.name ?? "B")"
        var sentences = ["\(names), sample by sample."]
        let ratesDiffer = job.a != nil && job.b != nil && abs((job.a?.sampleRate ?? 0) - (job.b?.sampleRate ?? 0)) >= 0.5
        if ratesDiffer {
            sentences.append("The second file is resampled to \(XORMath.rateLabel(rate)). Those are new integers, so this pass will not reverse exactly.")
        } else if job.clampedBits == 16 {
            sentences.append("XOR the result with the second file and the first one comes back.")
        } else {
            sentences.append("8-bit is the same XOR on a coarser integer.")
        }
        if job.span == .longer, let a = job.a, let b = job.b {
            let bCount = XORMath.resampledCount(frames: b.frames, fromRate: b.sampleRate, toRate: a.sampleRate)
            if a.frames != bCount {
                sentences.append("Past the shorter file, the missing side is zero, and XOR with zero leaves those samples as they are.")
            }
        }
        let slip = XORMath.slipSamples(milliseconds: job.slipMs, sampleRate: rate)
        if slip != 0 {
            let way = slip > 0 ? "later" : "earlier"
            let n = abs(slip)
            let unit = n == 1 ? "sample" : "samples"
            sentences.append("The second file starts \(n) \(unit) \(way).")
        }
        return (sentences.joined(separator: " "), false)
    }
}

enum Names {
    static func suggested(
        mode: ListenMode,
        fold: WaveFold,
        a: String,
        b: String,
        delayMs: Double = 10,
        stacked: Bool = false,
        pick: SourcePick = .first
    ) -> String {
        let head = pick == .second && !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? b : a
        if pick == .both && mode != .files {
            let pair = "\(clean(a))-and-\(clean(b))"
            switch mode {
            case .channels:
                return "\(pair)-channels.wav"
            case .waveform:
                return fold == .reverse ? "\(pair)-reverse.wav" : "\(pair)-halves.wav"
            case .delay:
                if stacked { return "\(pair)-delay-stack.wav" }
                return "\(pair)-delay-\(delayFileNote(delayMs)).wav"
            case .files:
                break
            }
        }
        switch mode {
        case .channels:
            return "\(clean(head))-channels.wav"
        case .waveform:
            return fold == .reverse ? "\(clean(head))-reverse.wav" : "\(clean(head))-halves.wav"
        case .files:
            return "\(clean(a))-xor-\(clean(b)).wav"
        case .delay:
            if stacked { return "\(clean(head))-delay-stack.wav" }
            return "\(clean(head))-delay-\(delayFileNote(delayMs)).wav"
        }
    }

    static func delayFileNote(_ ms: Double) -> String {
        let value = ms.isFinite ? ms : 0
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value.rounded()))ms"
        }
        return String(format: "%.1fms", value)
    }

    static func suggestedLoop(
        mode: ListenMode,
        fold: WaveFold,
        a: String,
        b: String,
        delayMs: Double = 10,
        stacked: Bool = false,
        pick: SourcePick = .first
    ) -> String {
        let once = suggested(mode: mode, fold: fold, a: a, b: b, delayMs: delayMs, stacked: stacked, pick: pick)
        if once.hasSuffix(".wav") {
            return String(once.dropLast(4)) + "-loop.wav"
        }
        return once + "-loop.wav"
    }

    static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "crosstalk" : trimmed
        let bad = CharacterSet(charactersIn: "/:\\")
        return base.components(separatedBy: bad).joined(separator: "-")
    }

    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let left = a.standardizedFileURL.resolvingSymlinksInPath().path
        let right = b.standardizedFileURL.resolvingSymlinksInPath().path
        return left == right
    }
}

enum BuiltIn {
    static let rate = 44_100.0
    static let amplitude: Float = 0.92

    /// One second of sine, then the same samples again.
    /// 220 Hz over one second is 220 cycles, so the join is the true continuation,
    /// and the two halves are the same waveform. XOR of the halves is silence.
    static func cycled(frequency: Double, rate: Double = BuiltIn.rate) -> [Float] {
        let n = max(1, Int(rate.rounded()))
        var once = [Float](repeating: 0, count: n)
        let amp = amplitude
        for i in 0..<n {
            let t = Double(i) / rate
            once[i] = amp * Float(sin(2 * Double.pi * frequency * t))
        }
        return once + once
    }

    static let pair: Clip = {
        let left = cycled(frequency: 220)
        let right = cycled(frequency: 330)
        return Clip(
            name: "220 and 330",
            url: nil,
            left: left,
            right: right,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: 2,
            truncated: false
        )
    }()

    /// The other built-in, so Both is not one tone XORed with itself.
    static let swapped: Clip = {
        let left = cycled(frequency: 330)
        let right = cycled(frequency: 220)
        return Clip(
            name: "330 and 220",
            url: nil,
            left: left,
            right: right,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: 2,
            truncated: false
        )
    }()

    static let low: Clip = mono(220, name: "220 Hz")
    static let high: Clip = mono(330, name: "330 Hz")

    /// A plain sine for Delay. It is not doubled, so Halves is not the point of it.
    static func tone(frequency: Double, seconds: Double = AppInfo.delayDemoSeconds, rate: Double = BuiltIn.rate) -> Clip {
        let hz = frequency.isFinite && frequency > 0 ? frequency : 220
        let span = seconds.isFinite ? max(0.01, seconds) : AppInfo.delayDemoSeconds
        let n = max(1, Int((span * rate).rounded()))
        var wave = [Float](repeating: 0, count: n)
        for i in 0..<n {
            wave[i] = XORMath.sine(index: i, frequency: hz, sampleRate: rate, amplitude: amplitude)
        }
        return Clip(
            name: Caption.frequencyText(hz),
            url: nil,
            left: wave,
            right: wave,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: 1,
            truncated: false
        )
    }

    static func mono(_ frequency: Double, name: String) -> Clip {
        let wave = cycled(frequency: frequency)
        return Clip(
            name: name,
            url: nil,
            left: wave,
            right: wave,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: rate,
            channelCount: 1,
            truncated: false
        )
    }
}

enum WAV {
    static func encode(left: [Int16], right: [Int16]?, sampleRate: Double) -> Data {
        let stereo = right != nil
        let channels: UInt16 = stereo ? 2 : 1
        let n = stereo ? min(left.count, right?.count ?? 0) : left.count
        let sr = UInt32(max(1, sampleRate.rounded()))
        let bits: UInt16 = 16
        let blockAlign = channels * (bits / 8)
        let byteRate = sr * UInt32(blockAlign)
        let dataBytes = UInt32(n) * UInt32(blockAlign)

        var data = Data()
        data.reserveCapacity(44 + Int(dataBytes))
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func sample(_ v: Int16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(channels)
        u32(sr)
        u32(byteRate)
        u16(blockAlign)
        u16(bits)
        ascii("data")
        u32(dataBytes)
        if let right, stereo {
            for i in 0..<n {
                sample(left[i])
                sample(right[i])
            }
        } else {
            for i in 0..<n { sample(left[i]) }
        }
        return data
    }

    /// 16-bit little-endian PCM only. Float, 24-bit, and compressed files return nil.
    static func decodePCM16(_ data: Data, name: String, url: URL?) -> Clip? {
        guard data.count >= 44 else { return nil }
        guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        guard String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        var format: UInt16 = 0
        var channels: UInt16 = 0
        var rate: UInt32 = 0
        var bits: UInt16 = 0
        var pcm: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = Int(u32(data, offset + 4))
            let start = offset + 8
            guard size >= 0, start + size <= data.count else { return nil }
            if id == "fmt ", size >= 16 {
                format = u16(data, start)
                channels = u16(data, start + 2)
                rate = u32(data, start + 4)
                bits = u16(data, start + 14)
            } else if id == "data", pcm == nil {
                pcm = data.subdata(in: start..<(start + size))
            }
            offset = start + size + (size & 1)
        }
        guard format == 1, bits == 16, (channels == 1 || channels == 2), rate > 0, let pcm else {
            return nil
        }
        let block = Int(channels) * 2
        guard block > 0, pcm.count >= block else { return nil }
        let available = pcm.count / block
        let cap = Int((AppInfo.maxSongSeconds * Double(rate)).rounded(.down))
        let frames = min(available, max(1, cap))
        var left = [Int16](repeating: 0, count: frames)
        var right = [Int16](repeating: 0, count: frames)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<frames {
                let at = i * block
                left[i] = Int16(bitPattern: UInt16(base[at]) | (UInt16(base[at + 1]) << 8))
                if channels == 2 {
                    right[i] = Int16(bitPattern: UInt16(base[at + 2]) | (UInt16(base[at + 3]) << 8))
                } else {
                    right[i] = left[i]
                }
            }
        }
        let floatL = left.map { Float($0) / 32767 }
        let floatR = right.map { Float($0) / 32767 }
        return Clip(
            name: name,
            url: url,
            left: floatL,
            right: floatR,
            pcmLeft: left,
            pcmRight: right,
            sampleRate: Double(rate),
            channelCount: Int(channels),
            truncated: available > frames
        )
    }

    private static func u16(_ data: Data, _ i: Int) -> UInt16 {
        UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func u32(_ data: Data, _ i: Int) -> UInt32 {
        UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}

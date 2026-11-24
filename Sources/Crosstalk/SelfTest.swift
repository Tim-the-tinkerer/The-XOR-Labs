import Foundation

enum SelfTest {
    static func run() -> String? {
        if let err = checkQuantizeAndXOR() { return err }
        if let err = checkInvolution() { return err }
        if let err = checkChannels() { return err }
        if let err = checkWaveform() { return err }
        if let err = checkFiles() { return err }
        if let err = checkResample() { return err }
        if let err = checkPCMBeatsFloat() { return err }
        if let err = checkBuiltIn() { return err }
        if let err = checkDelay() { return err }
        if let err = checkCombine() { return err }
        if let err = checkCaptions() { return err }
        if let err = checkNames() { return err }
        if let err = checkWAV() { return err }
        if let err = checkLoopExport() { return err }
        if let err = checkPlaybackRate() { return err }
        return nil
    }

    private static func checkQuantizeAndXOR() -> String? {
        if XORMath.quantize(0.5, bits: 16) != 16384 { return "0.5 did not quantize to 16384" }
        if XORMath.quantize(-0.5, bits: 16) != -16384 { return "-0.5 did not quantize to -16384" }
        if XORMath.quantize(1, bits: 16) != 32767 { return "full scale is not 32767" }
        if XORMath.quantize(-1, bits: 16) != -32767 { return "negative full scale is not -32767" }
        if XORMath.quantize(0, bits: 16) != 0 { return "zero did not quantize to 0" }
        if XORMath.quantize(1, bits: 8) != 127 { return "8-bit full scale is not 127" }
        if XORMath.quantize(-1, bits: 8) != -127 { return "8-bit negative full scale is not -127" }
        if XORMath.quantize(.nan, bits: 16) != 0 { return "NaN should quantize to 0" }
        if XORMath.xorBits(1000, 2000, bits: 16) != 1080 {
            return "1000 XOR 2000 should be 1080, not a sum"
        }
        if XORMath.xorBits(1000, 2000, bits: 16) == 3000 { return "XOR matched addition" }
        if XORMath.xorBits(-128, 127, bits: 8) != -1 { return "8-bit sign XOR failed" }
        if XORMath.slipSamples(milliseconds: 10, sampleRate: 44_100) != 441 {
            return "10 ms at 44100 Hz is not 441 samples"
        }
        if XORMath.slipSamples(milliseconds: 0, sampleRate: 44_100) != 0 { return "0 ms slip was not 0" }
        if XORMath.slipSamples(milliseconds: -1, sampleRate: 1000) != -1 { return "−1 ms at 1000 Hz is not −1 sample" }
        if XORMath.slipSamples(milliseconds: 9000, sampleRate: 1000) != 2000 {
            return "slip should clamp to 2000 ms"
        }
        let eight = XORMath.render(Job(mode: .channels, bits: 8, a: floats(left: [0.5], right: [0])))
        if eight.left != [64] { return "8-bit 0.5 XOR 0 should be 64, got \(eight.left)" }
        let wide = XORMath.render(Job(mode: .channels, bits: 16, a: floats(left: [0.5], right: [0])))
        if wide.left != [16384] { return "16-bit 0.5 XOR 0 should be 16384, got \(wide.left)" }
        if ExportPCM.scaleEight(127) != 32767 { return "8-bit export did not reach full scale" }
        if ExportPCM.scaleEight(0) != 0 { return "8-bit export moved a zero" }
        if ExportPCM.scaleEight(-127) != -32767 { return "8-bit export missed negative full scale" }
        return nil
    }

    private static func checkInvolution() -> String? {
        let values: [Int32] = [0, 1, -1, 32767, -32768, 1000, -16384, 2000, -2000]
        for a in values {
            for b in values {
                let once = XORMath.xorBits(a, b, bits: 16)
                let back = XORMath.xorBits(once, b, bits: 16)
                if back != a { return "\(a) XOR \(b) XOR \(b) came back as \(back)" }
            }
        }
        return nil
    }

    private static func checkChannels() -> String? {
        let mixed = XORMath.render(Job(
            mode: .channels,
            a: stereo(left: [1, 2], right: [4, 2])
        ))
        if mixed.left != [5, 0] || mixed.right != [5, 0] {
            return "channel XOR expected 5, 0 and got \(mixed.left)"
        }
        let monoTake = XORMath.render(Job(mode: .channels, a: mono([1, 2, 3])))
        if monoTake.left != [0, 0, 0] || !monoTake.erased {
            return "a mono file should XOR to silence"
        }
        if !monoTake.caption.contains("one channel") { return "mono caption: \(monoTake.caption)" }
        let agreed = XORMath.render(Job(mode: .channels, a: stereo(left: [9, 8], right: [9, 8])))
        if !agreed.erased || !agreed.caption.contains("agree") {
            return "matching channels should say they agree"
        }
        let original = mono([1, 2, 3, 4])
        _ = XORMath.render(Job(mode: .channels, a: original))
        if original.pcmLeft != [1, 2, 3, 4] { return "render changed the input" }
        return nil
    }

    private static func checkWaveform() -> String? {
        let clip = mono([1, 2, 3, 4])
        let once = XORMath.render(Job(mode: .waveform, fold: .reverse, a: clip))
        if once.left != [5, 1, 1, 5] { return "reverse XOR expected 5, 1, 1, 5 and got \(once.left)" }
        if once.right != once.left { return "mono reverse should be on both ears" }
        if !once.caption.contains("again is silence") { return "reverse caption: \(once.caption)" }
        let twice = XORMath.render(Job(mode: .waveform, fold: .reverse, a: mono(Array(once.left))))
        if twice.left.contains(where: { $0 != 0 }) || !twice.erased {
            return "reverse of a reverse XOR should be silence, got \(twice.left)"
        }
        let halves = XORMath.render(Job(mode: .waveform, fold: .halves, a: clip))
        if halves.left != [2, 6] { return "halves expected 2, 6 and got \(halves.left)" }
        if halves.caption.contains("middle") { return "an even length has no middle sample" }
        let odd = XORMath.render(Job(mode: .waveform, fold: .halves, a: mono([1, 2, 3, 4, 5])))
        if odd.left != [5, 7, 3] { return "odd halves expected 5, 7, 3 and got \(odd.left)" }
        if !odd.caption.contains("middle") { return "odd halves should mention the middle sample" }
        return nil
    }

    private static func checkFiles() -> String? {
        let a = mono([1, 2, 3, 4], name: "a")
        let b = mono([4, 1], name: "b")
        let shorter = XORMath.render(Job(mode: .files, a: a, b: b))
        if shorter.left != [5, 3] { return "shorter XOR expected 5, 3 and got \(shorter.left)" }
        if !shorter.caption.contains("comes back") { return "16-bit files should say the first comes back" }

        let longer = XORMath.render(Job(mode: .files, span: .longer, a: a, b: b))
        if longer.left != [5, 3, 3, 4] { return "longer tail expected 5, 3, 3, 4 and got \(longer.left)" }
        if !longer.caption.contains("zero") { return "longer caption should mention zero" }

        let looped = XORMath.render(Job(mode: .files, span: .loop, a: a, b: b))
        if looped.left != [5, 3, 7, 5] { return "loop expected 5, 3, 7, 5 and got \(looped.left)" }

        let slipped = XORMath.render(Job(mode: .files, slipMs: 1, a: a, b: b))
        if slipped.left != [6, 2] { return "slip +1 expected 6, 2 and got \(slipped.left)" }
        if !slipped.caption.contains("1 sample later") {
            return "slip caption: \(slipped.caption)"
        }

        let apart = XORMath.render(Job(mode: .files, slipMs: 10, a: a, b: b))
        if apart.count != 0 || !apart.caption.contains("no overlap") {
            return "a slip past the end should leave no overlap"
        }

        let early = XORMath.render(Job(mode: .files, span: .longer, slipMs: -1, a: a, b: b))
        if early.left != [0, 2, 3, 4] { return "slip −1 longer expected 0, 2, 3, 4 and got \(early.left)" }

        let spun = XORMath.render(Job(mode: .files, span: .loop, slipMs: 1, a: a, b: b))
        if spun.left != [0, 6, 2, 0] { return "loop slip expected 0, 6, 2, 0 and got \(spun.left)" }

        let stereoA = stereo(left: [1, 2], right: [3, 4])
        let monoB = mono([8, 1])
        let mixed = XORMath.render(Job(mode: .files, a: stereoA, b: monoB))
        if mixed.left != [9, 3] || mixed.right != [11, 5] {
            return "mono against stereo expected L 9, 3 and R 11, 5, got \(mixed.left) \(mixed.right)"
        }

        let same = XORMath.render(Job(mode: .files, span: .longer, a: a, b: mono([9, 8, 7, 6])))
        if same.caption.contains("zero") { return "equal lengths should not talk about a zero tail" }
        return nil
    }

    private static func checkResample() -> String? {
        if XORMath.resampledCount(frames: 4, fromRate: 100, toRate: 200) != 7 {
            return "4 samples from 100 Hz to 200 Hz should be 7"
        }
        if XORMath.resampledCount(frames: 5, fromRate: 44_100, toRate: 44_100) != 5 {
            return "matching rates should keep the sample count"
        }
        if XORMath.resampledCount(frames: 0, fromRate: 100, toRate: 200) != 0 {
            return "no samples should stay empty"
        }
        let end = XORMath.sourcePosition(index: 6, frames: 4, resampled: 7, fromRate: 100, toRate: 200)
        if end != 3 { return "the last resampled index should land on the last sample, got \(end)" }
        let mid = XORMath.sourcePosition(index: 1, frames: 4, resampled: 7, fromRate: 100, toRate: 200)
        if mid != 0.5 { return "index 1 of a 2× resample should be halfway, got \(mid)" }
        if XORMath.readLinear([0, 1, 0, -1], 2.5) != -0.5 { return "linear read at 2.5 failed" }
        if XORMath.readLinear([0, 1, 0, -1], 2) != 0 { return "an integer position should be that sample" }

        let silence = mono([Int16](repeating: 0, count: 7), rate: 200)
        let wave = Clip(
            name: "wave",
            url: nil,
            left: [0, 1, 0, -1],
            right: [0, 1, 0, -1],
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: 100,
            channelCount: 1,
            truncated: false
        )
        let resampled = XORMath.render(Job(mode: .files, a: silence, b: wave))
        let expect: [Int16] = [0, 16384, 32767, 16384, 0, -16384, -32767]
        if resampled.left != expect {
            return "resampled XOR expected \(expect) and got \(resampled.left)"
        }
        if !resampled.caption.contains("resampled") { return "resample caption: \(resampled.caption)" }
        return nil
    }

    private static func checkPCMBeatsFloat() -> String? {
        let a = Clip(
            name: "a",
            url: nil,
            left: [99, 99],
            right: [99, 99],
            pcmLeft: [0, 0],
            pcmRight: [0, 0],
            sampleRate: 1000,
            channelCount: 1,
            truncated: false
        )
        let b = Clip(
            name: "b",
            url: nil,
            left: [99, 99],
            right: [99, 99],
            pcmLeft: [1000, 2000],
            pcmRight: [1000, 2000],
            sampleRate: 1000,
            channelCount: 1,
            truncated: false
        )
        let take = XORMath.render(Job(mode: .files, a: a, b: b))
        if take.left != [1000, 2000] {
            return "16-bit WAV integers should be XORed, not the floats, got \(take.left)"
        }
        return nil
    }

    private static func checkBuiltIn() -> String? {
        let channels = XORMath.render(Job(mode: .channels, a: BuiltIn.pair, demo: true))
        if channels.erased || channels.count != 88_200 {
            return "built-in 220 XOR 330 should be heard, count \(channels.count)"
        }
        let halves = XORMath.render(Job(mode: .waveform, fold: .halves, a: BuiltIn.pair))
        if halves.count != 44_100 || halves.left.contains(where: { $0 != 0 }) || halves.right.contains(where: { $0 != 0 }) {
            return "built-in halves should be silence"
        }
        if !halves.caption.contains("halves agree") { return "built-in halves caption: \(halves.caption)" }
        let files = XORMath.render(Job(mode: .files, a: BuiltIn.low, b: BuiltIn.high, demo: true))
        if files.erased { return "220 XOR 330 should not be silence" }
        let waiting = XORMath.render(Job(mode: .files, a: mono([1, 2, 3]), b: nil))
        if !waiting.caption.contains("second file") || waiting.count != 0 {
            return "a missing second file should wait, not invent one"
        }
        return nil
    }

    private static func checkCaptions() -> String? {
        if !XORMath.fact.contains("1080") { return "the fact line lost 1080" }
        if Names.suggested(mode: .channels, fold: .reverse, a: "song", b: "") != "song-channels.wav" {
            return "channel export name changed"
        }
        if Names.suggested(mode: .waveform, fold: .halves, a: "song", b: "") != "song-halves.wav" {
            return "halves export name changed"
        }
        if Names.suggested(mode: .waveform, fold: .reverse, a: "song", b: "") != "song-reverse.wav" {
            return "reverse export name changed"
        }
        if Names.suggested(mode: .files, fold: .reverse, a: "a", b: "b") != "a-xor-b.wav" {
            return "files export name changed"
        }
        if Names.suggestedLoop(mode: .channels, fold: .reverse, a: "song", b: "") != "song-channels-loop.wav" {
            return "loop export name changed"
        }
        return nil
    }

    private static func checkLoopExport() -> String? {
        if ExportPCM.tile([1, 2, 3], count: 7) != [1, 2, 3, 1, 2, 3, 1] {
            return "a loop should repeat and cut the last pass"
        }
        if ExportPCM.tile([1, 2, 3], count: 2) != [1, 2] {
            return "a loop shorter than one pass should be a prefix"
        }
        if ExportPCM.tile([9], count: 4) != [9, 9, 9, 9] {
            return "a one-sample loop should repeat that sample"
        }
        if !ExportPCM.tile([], count: 4).isEmpty { return "an empty loop should stay empty" }
        if ExportPCM.frameCount(seconds: 1.5, sampleRate: 1000) != 1500 {
            return "1.5 s at 1000 Hz is not 1500 samples"
        }
        if ExportPCM.frameCount(seconds: 0, sampleRate: 1000) != 0 {
            return "zero seconds should export nothing"
        }
        if ExportPCM.frameCount(seconds: .nan, sampleRate: 1000) != 0 {
            return "a time that is not a number should export nothing"
        }
        if ExportPCM.frameCount(seconds: 900, sampleRate: 1000) != 600_000 {
            return "a loop should stop at 10 minutes"
        }
        if ExportPCM.durationLabel(frames: 30, sampleRate: 1) != "0:30" {
            return "30 seconds should read 0:30"
        }
        if ExportPCM.durationLabel(frames: 1500, sampleRate: 1000) != "1.50 s" {
            return "1.5 seconds should keep the fraction"
        }
        if ExportPCM.durationLabel(frames: 10, sampleRate: 1000) != "0.01 s" {
            return "a short loop should not read as 0:00"
        }
        let a = mono([1, 2, 3, 4], rate: 1000, name: "a")
        let b = mono([4, 1, 0, 0], rate: 1000, name: "b")
        let take = XORMath.render(Job(mode: .files, a: a, b: b))
        if take.left != [5, 3, 3, 4] { return "loop source XOR changed" }
        let looped = ExportPCM.repeated(take, seconds: 0.01)
        if looped.left != [5, 3, 3, 4, 5, 3, 3, 4, 5, 3] || looped.right != looped.left {
            return "10 ms loop expected two full passes and a cut, got \(looped.left)"
        }
        if ExportPCM.repeated(take, seconds: 0.002).left != [5, 3] {
            return "2 ms loop should be the first two samples"
        }
        if take.left != [5, 3, 3, 4] { return "looping changed the XOR" }
        let data = WAV.encode(left: looped.left, right: nil, sampleRate: 1000)
        if data.count != 44 + looped.left.count * 2 {
            return "looped WAV length changed"
        }
        let eight = XORMath.render(Job(mode: .channels, bits: 8, a: floats(left: [0.5], right: [0])))
        let scaled = ExportPCM.scaleEight(eight.left[0])
        let wide = ExportPCM.repeated(eight, seconds: 0.003)
        if wide.left != [scaled, scaled, scaled] || wide.right != wide.left {
            return "8-bit loop should repeat the scaled sample, got \(wide.left)"
        }
        return nil
    }

    private static func checkPlaybackRate() -> String? {
        let n = 44_100
        var pulse = [Int16](repeating: 0, count: n)
        pulse[22_050] = 16_000
        let zeros = [Int16](repeating: 0, count: n)
        let take = XORMath.render(Job(
            mode: .files,
            a: mono(pulse, rate: 22_050, name: "a"),
            b: mono(zeros, rate: 22_050, name: "b")
        ))
        if abs(take.sampleRate - 22_050) > 0.5 || take.left[22_050] != 16_000 {
            return "playback fixture was not a 22050 Hz impulse"
        }
        let engine = PlayEngine()
        engine.setGain(1)
        engine.setTake(take)
        guard let left = engine.renderOffline(outputRate: 48_000, frameCount: 52_000) else {
            return "offline playback did not render"
        }
        var peakIndex = 0
        var peak: Float = 0
        for (i, sample) in left.enumerated() {
            let magnitude = abs(sample)
            if magnitude > peak {
                peak = magnitude
                peakIndex = i
            }
        }
        if peak < 0.05 { return "resampled playback was silent" }
        if peakIndex < 40_000 {
            return "playback used the device clock (peak at sample \(peakIndex) of a 22050 Hz file)"
        }
        return nil
    }

    private static func checkNames() -> String? {
        let a = URL(fileURLWithPath: "/tmp/crosstalk-a.wav")
        let b = URL(fileURLWithPath: "/tmp/crosstalk-b.wav")
        if !Names.isSameFile(a, a) { return "a file should match itself" }
        if Names.isSameFile(a, b) { return "two paths were treated as one file" }
        if Names.clean("") != "crosstalk" { return "an empty name should become crosstalk" }
        return nil
    }

    private static func checkWAV() -> String? {
        let a = mono([1000, -1000, 32767, -32768, 0], rate: 1000, name: "a")
        let b = mono([2000, 2000, 1, 1, 7], rate: 1000, name: "b")
        let take = XORMath.render(Job(mode: .files, a: a, b: b))
        if take.left.first != 1080 { return "1000 XOR 2000 in a file should be 1080, got \(take.left)" }
        let data = WAV.encode(left: take.left, right: take.right, sampleRate: 1000)
        if data.count < 48 || data[44] != 0x38 || data[45] != 0x04 {
            return "WAV should store 1080 as 38 04"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crosstalk-selftest.wav")
        let monoURL = FileManager.default.temporaryDirectory.appendingPathComponent("crosstalk-selftest-mono.wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: monoURL)
        }
        do {
            try data.write(to: url)
            let loaded = try ClipLoader.load(url: url)
            if loaded.pcmLeft?.first != 1080 { return "reloaded XOR was not 1080" }
            if loaded.sampleRate != 1000 { return "reloaded rate was \(loaded.sampleRate)" }
            let back = XORMath.render(Job(mode: .files, a: loaded, b: b))
            if back.left != a.pcmLeft {
                return "XOR again with the second file should restore the first, got \(back.left)"
            }
            if back.right != a.pcmLeft {
                return "the restored right channel differed"
            }

            let monoData = WAV.encode(left: [1000, 2000], right: nil, sampleRate: 8000)
            try monoData.write(to: monoURL)
            let monoClip = try ClipLoader.load(url: monoURL)
            if monoClip.channelCount != 1 || monoClip.pcmLeft != [1000, 2000] {
                return "mono WAV should come back as one channel of 1000, 2000"
            }
            let erased = XORMath.render(Job(mode: .channels, a: monoClip))
            if !erased.erased { return "a reloaded mono file should XOR to silence" }
            if WAV.decodePCM16(Data(repeating: 0, count: 8), name: "no", url: nil) != nil {
                return "a short header should not decode"
            }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private static func checkDelay() -> String? {
        if let err = checkDelayCounts() { return err }
        if let err = checkDelayIntegers() { return err }
        if let err = checkDelaySine() { return err }
        if let err = checkDelayBlend() { return err }
        if let err = checkDelayNames() { return err }
        if XORVoice.capacity <= XORMath.delaySamples(milliseconds: 100, sampleRate: 192_000) {
            return "delay ring cannot hold 100 ms at 192 kHz"
        }
        return nil
    }

    private static func checkDelayCounts() -> String? {
        let cases: [(Double, Double, Int)] = [
            (10, 44_100, 441),
            (20, 44_100, 882),
            (50, 44_100, 2205),
            (10, 48_000, 480),
            (20, 48_000, 960),
            (50, 48_000, 2400),
            (1, 44_100, 44),
            (1.5, 1000, 2),
            (0.5, 1000, 1),
            (0, 44_100, 0),
            (-4, 44_100, 0),
            (1000, 1000, 100),
        ]
        for (ms, rate, want) in cases {
            let got = XORMath.delaySamples(milliseconds: ms, sampleRate: rate)
            if got != want {
                return "delay \(ms) ms at \(rate) Hz is \(got), expected \(want)"
            }
        }
        if AppInfo.stackMilliseconds != [10, 20, 50] { return "stack delays changed" }
        if XORMath.wholeCycles(frequency: 220, milliseconds: 50) != 11 {
            return "220 Hz at 50 ms should be 11 cycles"
        }
        if XORMath.wholeCycles(frequency: 220, milliseconds: 10) != nil {
            return "220 Hz at 10 ms is 2.2 cycles, not a whole number"
        }
        if XORMath.wholeCycles(frequency: 233, milliseconds: 50) != nil {
            return "233 Hz at 50 ms should not count as aligned"
        }
        return nil
    }

    private static func checkDelayIntegers() -> String? {
        let pair = mono([1000, 2000, 1000], rate: 1000, name: "pair")
        let slipped = XORMath.render(Job(mode: .delay, delayMs: 1, a: pair))
        if slipped.left != [1000, 1080, 1080] {
            return "1000 XOR the sample before it should be 1000, 1080, 1080, got \(slipped.left)"
        }
        if slipped.traceNow != [1000, 2000, 1000] || slipped.traceDelayed != [0, 1000, 2000] {
            return "the scope lost the two integers that met"
        }
        let quiet = XORMath.render(Job(mode: .delay, delayMs: 0, a: pair))
        if quiet.left.contains(where: { $0 != 0 }) || !quiet.erased {
            return "delay 0 should be silence"
        }
        if quiet.caption != "0 ms XORs each sample with itself. That is silence." {
            return "zero-delay caption was \(quiet.caption)"
        }
        let steady = mono([Int16](repeating: 1000, count: 40), rate: 1000)
        let held = XORMath.render(Job(mode: .delay, delayMs: 10, a: steady))
        let head = [Int16](repeating: 1000, count: 10)
        let tail = [Int16](repeating: 0, count: 30)
        if held.left != head + tail {
            return "a steady sample should pass through, then XOR to 0"
        }
        let extreme = mono([-32768, 1], rate: 1000)
        let kept = XORMath.render(Job(mode: .delay, delayMs: 10, a: extreme))
        if kept.left[0] != -32768 {
            return "delay should keep a stored −32768, got \(kept.left[0])"
        }
        let left = [Int16](repeating: 1000, count: 30)
        let right = [Int16](repeating: 2000, count: 30)
        let split = XORMath.render(Job(mode: .delay, delayMs: 10, ears: .leftOnly, a: stereo(left: left, right: right, rate: 1000)))
        if split.right != right { return "left only should leave the right channel as it was" }
        if split.left != [Int16](repeating: 1000, count: 10) + [Int16](repeating: 0, count: 20) {
            return "left only changed the XORed channel"
        }
        let copy = pair.left
        if XORMath.render(Job(mode: .delay, delayMs: 1, a: pair)).left != slipped.left {
            return "the same delay rendered two different XORs"
        }
        if pair.left != copy { return "delay render wrote into the input" }
        return nil
    }

    private static func checkDelaySine() -> String? {
        let ten = XORMath.render(Job(mode: .delay, delayMs: 10, toneHz: 220, a: sineClip(220, seconds: 1.2), demo: true))
        if ten.erased || ten.caption != "10 ms · 441 samples at 44.1 kHz. Disagreeing bits stay." {
            return "10 ms caption was \(ten.caption)"
        }
        let wet = ten.left[2000..<(2000 + 44_100)].map { XORMath.dequantize($0, bits: 16) }
        let fundamental = goertzel(wet, sampleRate: 44_100, frequency: 220)
        let octave = goertzel(wet, sampleRate: 44_100, frequency: 440)
        if octave < fundamental * 20 {
            return "10 ms sine should move to the octave (440 \(octave), 220 \(fundamental))"
        }
        let fifty = XORMath.render(Job(mode: .delay, delayMs: 50, toneHz: 220, a: sineClip(220, seconds: 1.2), demo: true))
        if fifty.caption != "50 ms is 11 cycles of 220 Hz. The copies agree, so XOR erases them." || !fifty.erased {
            return "50 ms caption was \(fifty.caption)"
        }
        let start = XORMath.delaySamples(milliseconds: 50, sampleRate: 44_100)
        for i in start..<fifty.count where fifty.left[i] != 0 {
            return "50 ms is 11 cycles of 220 Hz and should erase it, sample \(i) is \(fifty.left[i])"
        }
        let peak = 50
        let passed = XORMath.pack(XORMath.quantize(XORMath.sine(index: peak, frequency: 220, sampleRate: 44_100), bits: 16))
        if fifty.left[peak] != passed {
            return "before the delay fills, sample \(peak) should pass through, got \(fifty.left[peak])"
        }
        let stacked = XORMath.render(Job(mode: .delay, stacked: true, toneHz: 220, a: sineClip(220, seconds: 1.5), demo: true))
        if stacked.caption != "The stack erased this 220 Hz tone. A stage lined up with the pitch it was given." {
            return "stack caption was \(stacked.caption)"
        }
        let settle = XORMath.delaySamples(milliseconds: AppInfo.stackSettleMilliseconds, sampleRate: 44_100)
        for i in settle..<stacked.count where stacked.left[i] != 0 {
            return "stack should erase 220 Hz once the stages line up, sample \(i) is \(stacked.left[i])"
        }
        let alive = XORMath.render(Job(mode: .delay, stacked: true, toneHz: 233, a: sineClip(233, seconds: 1.5), demo: true))
        let aliveTail = alive.left[8000...].map { XORMath.dequantize($0, bits: 16) }
        if rms(aliveTail) < 0.3 {
            return "stack at 233 Hz should stay audible, RMS \(rms(aliveTail))"
        }
        let aliveFund = goertzel(aliveTail, sampleRate: 44_100, frequency: 233)
        let aliveOctave = goertzel(aliveTail, sampleRate: 44_100, frequency: 466)
        if aliveOctave < aliveFund * 8 {
            return "stack at 233 Hz should favor the octave (466 \(aliveOctave), 233 \(aliveFund))"
        }
        let coarse = XORMath.render(Job(mode: .delay, bits: 8, delayMs: 10, a: sineClip(220, seconds: 1.2), demo: true))
        let coarseWet = coarse.left[2000..<(2000 + 44_100)].map { XORMath.dequantize($0, bits: 8) }
        let coarseFund = goertzel(coarseWet, sampleRate: 44_100, frequency: 220)
        let coarseOctave = goertzel(coarseWet, sampleRate: 44_100, frequency: 440)
        if coarseOctave < coarseFund * 10 {
            return "8-bit XOR should still move a sine to the octave"
        }
        if !coarse.caption.contains("coarser integer") {
            return "8-bit delay caption was \(coarse.caption)"
        }
        var sweptJob = Job(mode: .delay, delayMs: 10, sweepHz: 2, sweepDepth: 5, a: sineClip(220, seconds: 0.4), demo: true)
        let swept = XORMath.render(sweptJob)
        sweptJob.sweepHz = 0
        sweptJob.sweepDepth = 0
        let still = XORMath.render(sweptJob)
        if swept.left == still.left { return "sweep should move the delay" }
        if swept.caption != "The delay moves around 10 ms across the file. It jumps by whole samples." {
            return "sweep caption was \(swept.caption)"
        }
        let constant = [Float](repeating: 0.5, count: 2000)
        let steadyClip = Clip(
            name: "steady", url: nil, left: constant, right: constant,
            pcmLeft: nil, pcmRight: nil, sampleRate: 44_100, channelCount: 1, truncated: false
        )
        let moving = XORMath.render(Job(mode: .delay, delayMs: 10, sweepHz: 1, sweepDepth: 5, a: steadyClip))
        if moving.left[0] == 0 { return "a swept delay should pass the first sample through" }
        for i in 800..<moving.count where moving.left[i] != 0 {
            return "a steady sample should still XOR to 0 once the sweep has filled, sample \(i)"
        }
        let plain = XORMath.render(Job(mode: .delay, delayMs: 10, a: sineClip(220, seconds: 0.2), demo: true))
        let blended = XORMath.render(Job(
            mode: .delay, delayMs: 10, blendEnabled: true, blend: 0.25,
            a: sineClip(220, seconds: 0.2), demo: true
        ))
        if plain.left != blended.left { return "blend should not change the tone" }
        return nil
    }

    private static func checkDelayBlend() -> String? {
        let n = 1200
        let left = (0..<n).map { XORMath.sine(index: $0, frequency: 220, sampleRate: 44_100) }
        let right = (0..<n).map { XORMath.sine(index: $0, frequency: 330, sampleRate: 44_100) }
        let clip = Clip(
            name: "pair", url: nil, left: left, right: right,
            pcmLeft: nil, pcmRight: nil, sampleRate: 44_100, channelCount: 2, truncated: false
        )
        let plain = XORMath.render(Job(mode: .delay, delayMs: 10, a: clip))
        var mid = Job(mode: .delay, delayMs: 10, blendEnabled: true, blend: 0.5, a: clip)
        let blended = XORMath.render(mid)
        if plain.left == blended.left { return "blend should change a stereo file" }
        if blended.caption != "10 ms · 441 samples at 44.1 kHz. The left and right are blended before the XOR." {
            return "blend caption was \(blended.caption)"
        }
        let avg = zip(left, right).map { $0 * 0.5 + $1 * 0.5 }
        let via = XORMath.render(Job(mode: .delay, delayMs: 10, a: Clip(
            name: "avg", url: nil, left: avg, right: avg,
            pcmLeft: nil, pcmRight: nil, sampleRate: 44_100, channelCount: 1, truncated: false
        )))
        if blended.left != via.left || blended.right != via.right {
            return "a halfway blend should XOR the average of the two channels"
        }
        mid.blend = 0
        let asLeft = XORMath.render(mid)
        if asLeft.caption != "10 ms · 441 samples at 44.1 kHz. The left channel is used on both sides, then the XOR." {
            return "left blend caption was \(asLeft.caption)"
        }
        let leftBoth = XORMath.render(Job(mode: .delay, delayMs: 10, a: Clip(
            name: "left", url: nil, left: left, right: left,
            pcmLeft: nil, pcmRight: nil, sampleRate: 44_100, channelCount: 1, truncated: false
        )))
        if asLeft.left != leftBoth.left || asLeft.right != leftBoth.right {
            return "blend at 0 should use the left channel on both sides"
        }
        mid.blend = 1
        let asRight = XORMath.render(mid)
        let rightBoth = XORMath.render(Job(mode: .delay, delayMs: 10, a: Clip(
            name: "right", url: nil, left: right, right: right,
            pcmLeft: nil, pcmRight: nil, sampleRate: 44_100, channelCount: 1, truncated: false
        )))
        if asRight.left != rightBoth.left || asRight.right != rightBoth.right {
            return "blend at 1 should use the right channel on both sides"
        }
        mid.blend = 0.5
        mid.ears = .leftOnly
        let split = XORMath.render(mid)
        let dry = XORMath.pack(XORMath.quantize(left[0] * 0.5 + right[0] * 0.5, bits: 16))
        if split.right[0] != dry {
            return "left only should keep the blended sample on the right, got \(split.right[0])"
        }
        return nil
    }

    private static func checkCombine() -> String? {
        let mixed = XORMath.combine(held([1080, 1080, 1080]), held([1, 2]), mode: .channels)
        if mixed.left != [1081, 1082] || mixed.right != [1081, 1082] {
            return "1080 XOR 1 and 2 should be 1081 and 1082, got \(mixed.left)"
        }
        if mixed.count != 2 { return "the shorter result should set the length, got \(mixed.count)" }
        if !mixed.caption.contains("Channels on each file") || !mixed.caption.contains("shorter one sets the length") {
            return "combine caption: \(mixed.caption)"
        }
        let kept = XORMath.combine(held([-32768]), held([0]), mode: .channels)
        if kept.left.first != -32768 {
            return "matching rates should keep −32768, got \(String(describing: kept.left.first))"
        }
        let quiet = XORMath.render(Job(mode: .channels, a: mono([4, 5, 6, 7])))
        let loud = XORMath.render(Job(mode: .channels, a: stereo(left: [1000, 2000], right: [2000, 1000])))
        let passed = XORMath.combine(quiet, loud, mode: .channels)
        if passed.left != [1080, 1080] {
            return "silence XOR the other result should be that result, got \(passed.left)"
        }
        if XORMath.resampledCount(frames: 4, fromRate: 2000, toRate: 1000) != 3 {
            return "4 samples at 2000 Hz onto 1000 Hz should be 3"
        }
        let aligned = XORMath.combine(held([0, 0, 0, 0, 0], rate: 1000), held([1000, 1000, 1000, 1000], rate: 2000), mode: .delay)
        if aligned.count != 3 {
            return "a faster second result should land on 3 samples, got \(aligned.count)"
        }
        if !aligned.caption.contains("will not reverse exactly") {
            return "rate mismatch caption: \(aligned.caption)"
        }
        if !aligned.caption.contains("delayed") { return "delay combine caption: \(aligned.caption)" }
        let folded = XORMath.combine(held([3, 1]), held([1]), mode: .waveform)
        if !folded.caption.contains("folded") { return "fold combine caption: \(folded.caption)" }
        let eight = XORMath.combine(held([9, 1], bits: 8), held([1, 1], bits: 8), mode: .channels)
        if eight.left.first != 8 || !eight.caption.contains("coarser integer") {
            return "8-bit combine: \(eight.left) \(eight.caption)"
        }
        let agreed = XORMath.combine(held([0, 0]), held([0, 0]), mode: .channels)
        if !agreed.erased || agreed.caption != "These samples agree, so XOR erases them." {
            return "agreed results: \(agreed.caption)"
        }
        if Names.suggested(mode: .channels, fold: .reverse, a: "a", b: "b", pick: .both) != "a-and-b-channels.wav" {
            return "both channels name changed"
        }
        if Names.suggested(mode: .waveform, fold: .halves, a: "a", b: "b", pick: .both) != "a-and-b-halves.wav" {
            return "both halves name changed"
        }
        if Names.suggested(mode: .delay, fold: .reverse, a: "a", b: "b", delayMs: 10, pick: .both) != "a-and-b-delay-10ms.wav" {
            return "both delay name changed"
        }
        if Names.suggestedLoop(mode: .channels, fold: .reverse, a: "a", b: "b", pick: .both) != "a-and-b-channels-loop.wav" {
            return "both loop name changed"
        }
        if Names.suggested(mode: .channels, fold: .reverse, a: "a", b: "b", pick: .second) != "b-channels.wav" {
            return "second file should name the export"
        }
        if Names.suggested(mode: .channels, fold: .reverse, a: "song", b: "") != "song-channels.wav" {
            return "default export name changed"
        }
        return nil
    }

    private static func held(_ samples: [Int16], rate: Double = 1000, bits: Int = 16) -> Take {
        Take(
            left: samples,
            right: samples,
            plan: Plan.empty(bits: bits),
            sampleRate: rate,
            bits: bits,
            picture: .empty,
            caption: "",
            erased: false,
            demo: false
        )
    }

    private static func checkDelayNames() -> String? {
        if Names.suggested(mode: .delay, fold: .reverse, a: "song", b: "", delayMs: 10) != "song-delay-10ms.wav" {
            return "delay export name changed"
        }
        if Names.suggested(mode: .delay, fold: .reverse, a: "song", b: "", delayMs: 12.5) != "song-delay-12.5ms.wav" {
            return "fractional delay export name changed"
        }
        if Names.suggested(mode: .delay, fold: .reverse, a: "song", b: "", stacked: true) != "song-delay-stack.wav" {
            return "stack export name changed"
        }
        if Names.suggestedLoop(mode: .delay, fold: .reverse, a: "song", b: "", delayMs: 20) != "song-delay-20ms-loop.wav" {
            return "delay loop name changed"
        }
        return nil
    }

    private static func sineClip(_ hz: Double, seconds: Double) -> Clip {
        let rate = 44_100.0
        let n = max(1, Int((seconds * rate).rounded()))
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = XORMath.sine(index: i, frequency: hz, sampleRate: rate)
        }
        return Clip(
            name: "sine", url: nil, left: samples, right: samples,
            pcmLeft: nil, pcmRight: nil, sampleRate: rate, channelCount: 1, truncated: false
        )
    }

    private static func goertzel(_ samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        let n = samples.count
        guard n > 8, sampleRate > 0, frequency > 0 else { return 0 }
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cw = 2.0 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for x in samples {
            let s0 = Double(x) + cw * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - cw * s1 * s2
        return sqrt(max(0, power)) / Double(n)
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for v in samples { sum += Double(v) * Double(v) }
        return sqrt(sum / Double(samples.count))
    }

    private static func mono(_ samples: [Int16], rate: Double = 1000, name: String = "mono") -> Clip {
        let floats = samples.map { Float($0) / 32767 }
        return Clip(
            name: name,
            url: nil,
            left: floats,
            right: floats,
            pcmLeft: samples,
            pcmRight: samples,
            sampleRate: rate,
            channelCount: 1,
            truncated: false
        )
    }

    private static func stereo(left: [Int16], right: [Int16], rate: Double = 1000) -> Clip {
        Clip(
            name: "stereo",
            url: nil,
            left: left.map { Float($0) / 32767 },
            right: right.map { Float($0) / 32767 },
            pcmLeft: left,
            pcmRight: right,
            sampleRate: rate,
            channelCount: 2,
            truncated: false
        )
    }

    private static func floats(left: [Float], right: [Float]) -> Clip {
        Clip(
            name: "float",
            url: nil,
            left: left,
            right: right,
            pcmLeft: nil,
            pcmRight: nil,
            sampleRate: 1000,
            channelCount: 2,
            truncated: false
        )
    }
}

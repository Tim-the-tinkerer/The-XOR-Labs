import Foundation

enum AppInfo {
    static let name = "Crosstalk"
    static let version = "1.3.0"
    static let build = "5"
    static let bundleID = "com.tim.crosstalk"

    /// Built-in tones and the clock of a file whose rate we already trust.
    static let renderRate = 44_100.0
    /// Loaded files keep at most this much audio. The rest is not read.
    static let maxSongSeconds = 600.0
    /// Playback level. Export writes the XOR at full scale.
    static let playbackGain: Float = 0.4
    /// How far the second file can slide, either way.
    static let maxSlipMilliseconds = 2_000.0
    /// Longest delay the rings will honor, including sweep.
    static let maxDelayMilliseconds = 100.0
    /// The delay slider stops here so sweep still fits under the ring limit.
    static let delaySliderMax = 80.0
    static let maxSweepHz = 4.0
    static let maxSweepDepthMilliseconds = 20.0
    /// The three delays in a stack, in order.
    static let stackMilliseconds: [Double] = [10, 20, 50]
    /// How far into a stack to look before calling the tail silence.
    static let stackSettleMilliseconds = 500.0
    /// The built-in delay tone. Playback loops it.
    static let delayDemoSeconds = 8.0
    static let minToneHz = 40.0
    static let maxToneHz = 880.0
}

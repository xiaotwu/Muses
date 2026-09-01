import AVFoundation

/// Convert an `AVAudioPlayerNode` render timestamp into file seconds.
/// `segmentStart` is the file time of the currently scheduled segment (0 after
/// a full-file load, the seek target after seek, the AVPlayer handoff time
/// after a streaming swap). Node sample time is **not** file position.
enum PlayerPosition {
    static func seconds(player: AVAudioPlayerNode,
                        segmentStart: Double,
                        fileSampleRate: Double) -> Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return segmentStart
        }
        let sr = playerTime.sampleRate > 0 ? playerTime.sampleRate : fileSampleRate
        guard sr > 0 else { return segmentStart }
        return segmentStart + Double(playerTime.sampleTime) / sr
    }

    static func seconds(segmentStart: Double,
                        playerSampleTime: AVAudioFramePosition,
                        playerSampleRate: Double) -> Double {
        guard playerSampleRate > 0 else { return segmentStart }
        return segmentStart + Double(playerSampleTime) / playerSampleRate
    }
}

import Foundation
import Testing
@testable import TournesolCore

/// Something music-like: a few tones plus noise, so a delay is findable but not trivially periodic.
private func music(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
    var state = seed
    func noise() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 1000) / 1000
    }
    return (0..<Int(seconds * rate)).map { n in
        let t = Double(n) / rate
        let tones = sin(2 * .pi * 220 * t) + 0.6 * sin(2 * .pi * 330 * t + 1) + 0.3 * sin(2 * .pi * 554 * t)
        return Float(tones * (0.5 + 0.5 * sin(2 * .pi * 2 * t))) + 0.4 * noise()
    }
}

@Suite struct AudioAlignmentTests {
    private let rate = 16_000.0

    @Test func findsTheDelayBetweenTwoRecordingsOfTheSamePassage() throws {
        let song = music(seconds: 10, rate: rate, seed: 1)
        let start = Int(2 * rate)
        let earlier = Array(song[start..<(start + Int(4 * rate))])
        // The second recording starts 0.437 s before the passage and is a bit noisy and quieter, like another speaker.
        var state: UInt64 = 7
        let laterStart = start - Int(0.437 * rate)
        let later = song[laterStart..<(laterStart + Int(5 * rate))].map { sample -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.5 * sample + 0.3 * Float(Int64(bitPattern: state >> 11) % 1000) / 1000
        }
        let match = try #require(AudioAlignment.match(earlier, in: later, sampleRate: rate, minLag: 0, maxLag: 1))
        #expect(abs(match.lag - 0.437) < 0.001)
        #expect(match.confidence > 8, "\(match.confidence)")
    }

    @Test func unrelatedSoundGivesLowConfidence() throws {
        let earlier = music(seconds: 4, rate: rate, seed: 3)
        let later = (0..<Int(5 * rate)).map { n in Float(sin(Double(n) * 0.37) * 0.1) }
        let match = try #require(AudioAlignment.match(earlier, in: later, sampleRate: rate, minLag: 0, maxLag: 1))
        #expect(match.confidence < 8, "\(match.confidence)")
    }
}

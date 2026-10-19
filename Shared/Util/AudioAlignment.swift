//
//  AudioAlignment.swift
//  Tournesol
//
//  Finds how far apart two recordings of the same music are, for fine-tuning a Jam by ear.
//

import Accelerate
import Foundation

nonisolated enum AudioAlignment {
    struct Match: Equatable {
        /// Seconds into `later` where `earlier` starts.
        var lag: TimeInterval
        /// How many standard deviations the best match stands above the rest; below about 8 it's guesswork.
        var confidence: Double
    }

    /// Cross-correlates two recordings with every frequency weighted equally (GCC-PHAT), which keeps the peak sharp for
    /// music heard through different speakers and rooms. Only lags between `minLag` and `maxLag` seconds are considered.
    static func match(_ earlier: [Float], in later: [Float], sampleRate: Double, minLag: TimeInterval, maxLag: TimeInterval) -> Match? {
        guard !earlier.isEmpty, !later.isEmpty, sampleRate > 0 else { return nil }
        let needed = earlier.count + later.count
        let log2n = Int.bitWidth - (needed - 1).leadingZeroBitCount
        let size = 1 << log2n
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func spectrum(_ signal: [Float]) -> (real: [Float], imaginary: [Float]) {
            var padded = signal + [Float](repeating: 0, count: size - signal.count)
            var real = [Float](repeating: 0, count: size / 2)
            var imaginary = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    padded.withUnsafeMutableBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
            return (real, imaginary)
        }

        let a = spectrum(earlier)
        let b = spectrum(later)
        // conj(A) · B, then divide by its magnitude so only the phase, i.e. the delay, is left.
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        for i in 0..<(size / 2) {
            if i == 0 {
                // Packed: DC in real[0], Nyquist in imaginary[0].
                real[0] = a.real[0] * b.real[0] >= 0 ? 1 : -1
                imaginary[0] = a.imaginary[0] * b.imaginary[0] >= 0 ? 1 : -1
                continue
            }
            let re = a.real[i] * b.real[i] + a.imaginary[i] * b.imaginary[i]
            let im = a.real[i] * b.imaginary[i] - a.imaginary[i] * b.real[i]
            let magnitude = max((re * re + im * im).squareRoot(), 1e-12)
            real[i] = re / magnitude
            imaginary[i] = im / magnitude
        }

        var correlation = [Float](repeating: 0, count: size)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                correlation.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(size / 2))
                }
            }
        }

        let first = max(0, Int((minLag * sampleRate).rounded(.down)))
        let last = min(later.count - 1, Int((maxLag * sampleRate).rounded(.up)))
        guard first < last else { return nil }
        var best = first
        for index in first...last where correlation[index] > correlation[best] { best = index }
        let window = correlation[first...last].map(Double.init)
        let mean = window.reduce(0, +) / Double(window.count)
        let deviation = max((window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)).squareRoot(), 1e-12)
        return Match(lag: Double(best) / sampleRate, confidence: (Double(correlation[best]) - mean) / deviation)
    }
}

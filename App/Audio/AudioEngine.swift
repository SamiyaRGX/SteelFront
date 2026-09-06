//
//  AudioEngine.swift
//  SteelFront
//
//  Every sound is synthesised at launch from noise and envelopes, so the game
//  ships without a single audio file. A small pool of player nodes lets shots
//  overlap without cutting each other off.
//

import Foundation
import AVFoundation

final class AudioEngine {

    enum Sound: String, CaseIterable {
        case shotLight, shotRifle, shotShotgun, shotSniper, shotLauncher, shotRail
        case explosion, impact, flesh, headshot, reload, dryFire, hurt, pickup
        case drone, death
    }

    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var voiceIndex = 0
    private let sampleRate: Double = 44_100
    private(set) var isRunning = false

    init?() {
        configureSession()
        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format())
            voices.append(node)
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            return nil
        }
        for sound in Sound.allCases {
            buffers[sound] = render(sound)
        }
    }

    private func format() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func play(_ sound: Sound, volume: Float = 1, pitch: Float = 1) {
        guard isRunning, let buffer = buffers[sound], !voices.isEmpty else { return }
        let node = voices[voiceIndex]
        voiceIndex = (voiceIndex + 1) % voices.count
        node.volume = max(0, min(1, volume))
        if !node.isPlaying { node.play() }
        // Slight rate variation keeps repeated shots from sounding robotic.
        let rate = max(0.5, min(2, pitch))
        if absf(rate - 1) > 0.01, let shifted = timeStretch(buffer, rate: rate) {
            node.scheduleBuffer(shifted, at: nil, options: .interrupts)
        } else {
            node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        }
    }

    func stopAll() {
        for node in voices { node.stop() }
    }

    // MARK: - Synthesis

    private func render(_ sound: Sound) -> AVAudioPCMBuffer? {
        let (seconds, generator): (Double, (Int, Int) -> Float) = {
            switch sound {
            case .shotLight:
                return (0.22, { t, n in
                    let env = exp(-Float(t) / Float(n) * 14)
                    return (self.noise() * 0.9 + sinf(Float(t) * 0.09) * 0.4) * env
                })
            case .shotRifle:
                return (0.30, { t, n in
                    let env = exp(-Float(t) / Float(n) * 11)
                    return (self.noise() * 1.0 + sinf(Float(t) * 0.06) * 0.6) * env
                })
            case .shotShotgun:
                return (0.55, { t, n in
                    let env = exp(-Float(t) / Float(n) * 6)
                    return (self.noise() * 1.2 + sinf(Float(t) * 0.035) * 0.9) * env
                })
            case .shotSniper:
                return (0.70, { t, n in
                    let env = exp(-Float(t) / Float(n) * 5)
                    let crack = exp(-Float(t) / Float(n) * 40) * sinf(Float(t) * 0.22)
                    return (self.noise() * 0.8 + crack * 1.4 + sinf(Float(t) * 0.02) * 0.7) * env
                })
            case .shotLauncher:
                return (0.45, { t, n in
                    let env = exp(-Float(t) / Float(n) * 7)
                    return (self.noise() * 0.7 + sinf(Float(t) * 0.04) * 0.8) * env
                })
            case .shotRail:
                return (0.60, { t, n in
                    let env = exp(-Float(t) / Float(n) * 6)
                    let sweep = sinf(Float(t) * (0.3 - Float(t) / Float(n) * 0.2))
                    return (self.noise() * 0.35 + sweep * 0.9) * env
                })
            case .explosion:
                return (1.30, { t, n in
                    let env = exp(-Float(t) / Float(n) * 4)
                    let rumble = sinf(Float(t) * 0.012) + sinf(Float(t) * 0.007) * 0.6
                    return (self.noise() * 0.7 + rumble * 0.8) * env
                })
            case .impact:
                return (0.10, { t, n in
                    let env = exp(-Float(t) / Float(n) * 30)
                    return self.noise() * env
                })
            case .flesh:
                return (0.16, { t, n in
                    let env = exp(-Float(t) / Float(n) * 18)
                    return (self.noise() * 0.5 + sinf(Float(t) * 0.05) * 0.5) * env
                })
            case .headshot:
                return (0.22, { t, n in
                    let env = exp(-Float(t) / Float(n) * 16)
                    let tone = sinf(Float(t) * (t < n / 2 ? 0.30 : 0.42))
                    return (tone * 0.7 + self.noise() * 0.3) * env
                })
            case .reload:
                return (0.34, { t, n in
                    let first = Float(t) < Float(n) * 0.35
                    let env = exp(-Float(t % (n / 2)) / Float(n) * 40)
                    return self.noise() * env * (first ? 0.9 : 0.6)
                })
            case .dryFire:
                return (0.06, { t, n in
                    let env = exp(-Float(t) / Float(n) * 45)
                    return self.noise() * env * 0.7
                })
            case .hurt:
                return (0.30, { t, n in
                    let env = exp(-Float(t) / Float(n) * 9)
                    return (self.noise() * 0.4 + sinf(Float(t) * 0.03) * 0.8) * env
                })
            case .pickup:
                return (0.28, { t, n in
                    let env = exp(-Float(t) / Float(n) * 6)
                    let sweep = sinf(Float(t) * (0.18 + Float(t) / Float(n) * 0.25))
                    return sweep * env * 0.7
                })
            case .drone:
                return (0.50, { t, n in
                    let env = exp(-Float(t) / Float(n) * 3)
                    return (self.noise() * 0.25 + sinf(Float(t) * 0.16) * 0.35) * env
                })
            case .death:
                return (1.60, { t, n in
                    let env = exp(-Float(t) / Float(n) * 2.5)
                    let sweep = sinf(Float(t) * (0.14 - Float(t) / Float(n) * 0.10))
                    return (sweep * 0.6 + self.noise() * 0.3) * env
                })
            }
        }()

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format(),
                                            frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return nil }
        let total = Int(frameCount)
        for index in 0..<total {
            let sample = max(-1, min(1, generator(index, total) * 0.55))
            left[index] = sample
            right[index] = sample
        }
        return buffer
    }

    private var noiseState: UInt64 = 0x1234_5678

    private func noise() -> Float {
        noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
        let bits = UInt32(truncating: noiseState >> 33)
        return Float(Int32(bitPattern: bits)) / 2147483647.0
    }

    /// Naive resample used for pitch variation.
    private func timeStretch(_ buffer: AVAudioPCMBuffer, rate: Float) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0] else { return nil }
        let sourceCount = Int(buffer.frameLength)
        let targetCount = max(64, Int(Float(sourceCount) / rate))
        guard let out = AVAudioPCMBuffer(pcmFormat: format(),
                                         frameCapacity: AVAudioFrameCount(targetCount)),
              let outLeft = out.floatChannelData?[0],
              let outRight = out.floatChannelData?[1] else { return nil }
        out.frameLength = AVAudioFrameCount(targetCount)
        for index in 0..<targetCount {
            let sourceIndex = min(sourceCount - 1, Int(Float(index) * rate))
            outLeft[index] = source[sourceIndex]
            outRight[index] = source[sourceIndex]
        }
        return out
    }
}

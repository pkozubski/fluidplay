// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation
import os

/// Plays PCM audio from the console with a small buffer that evens out uneven network delivery.
final class AudioPlayer {
    private struct Ring {
        var storage: [Int16] = []
        var readIndex = 0
        var count = 0
        var channels = 2
        var primed = false
        var primeSamples = 0
        var maxSamples = 0
        var resyncSamples = 0
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring = OSAllocatedUnfairLock(initialState: Ring())
    private let queue = DispatchQueue(label: "veyramac.audio")
    private var configured: (channels: Int, rate: Double)?
    private var stopped = false

    /// Volume 0…1 (the engine's mixer survives an audio format change).
    func setVolume(_ volume: Float) {
        queue.async { [weak self] in
            self?.engine.mainMixerNode.outputVolume = max(0, min(1, volume))
        }
    }

    /// Accepts interleaved samples. Called from a chiaki thread.
    func push(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int, rate: Double) {
        guard frames > 0, channels > 0 else { return }
        if configured?.channels != channels || configured?.rate != rate {
            configured = (channels, rate)
            queue.async { [weak self] in self?.configure(channels: channels, rate: rate) }
        }
        let total = frames * channels
        ring.withLock { ring in
            guard ring.channels == channels, ring.storage.count >= total else { return }
            let capacity = ring.storage.count
            // Too much latency (e.g. after a network hitch): drop the oldest samples.
            if ring.count + total > ring.maxSamples {
                let drop = ring.count - ring.resyncSamples
                if drop > 0 {
                    ring.readIndex = (ring.readIndex + drop) % capacity
                    ring.count -= drop
                }
            }
            var writeIndex = (ring.readIndex + ring.count) % capacity
            for i in 0..<total {
                ring.storage[writeIndex] = samples[i]
                writeIndex += 1
                if writeIndex == capacity { writeIndex = 0 }
            }
            ring.count += total
            if !ring.primed, ring.count >= ring.primeSamples { ring.primed = true }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            engine.stop()
            if let sourceNode {
                engine.detach(sourceNode)
                self.sourceNode = nil
            }
        }
    }

    private func configure(channels: Int, rate: Double) {
        guard !stopped else { return }
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        ring.withLock { ring in
            ring.channels = channels
            ring.storage = [Int16](repeating: 0, count: Int(rate) * channels) // 1 s
            ring.readIndex = 0
            ring.count = 0
            ring.primed = false
            ring.primeSamples = Int(rate * 0.04) * channels
            ring.maxSamples = Int(rate * 0.25) * channels
            ring.resyncSamples = Int(rate * 0.06) * channels
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let outputs = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let produced: Int = ring.withLock { ring in
                guard ring.primed else { return 0 }
                let sourceChannels = ring.channels
                let available = min(frames, ring.count / sourceChannels)
                let capacity = ring.storage.count
                for frame in 0..<available {
                    let base = (ring.readIndex + frame * sourceChannels) % capacity
                    for (channel, output) in outputs.enumerated() {
                        guard let data = output.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                        let sourceChannel = min(channel, sourceChannels - 1)
                        data[frame] = Float32(ring.storage[(base + sourceChannel) % capacity]) / 32768
                    }
                }
                ring.readIndex = (ring.readIndex + available * sourceChannels) % capacity
                ring.count -= available * sourceChannels
                // The buffer ran dry — build up the reserve again instead of crackling.
                if available < frames { ring.primed = false }
                return available
            }
            if produced < frames {
                for output in outputs {
                    guard let data = output.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                    for frame in produced..<frames { data[frame] = 0 }
                }
            }
            isSilence.pointee = ObjCBool(produced == 0)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        do {
            try engine.start()
        } catch {
            NSLog("VeyraMac: couldn't start audio: %@", error.localizedDescription)
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Decodes an Annex B stream (H.264 / H.265) in hardware via VideoToolbox into NV12 buffers.
/// `decode` may be called from only one thread (the chiaki video thread).
final class VideoDecoder {
    enum Codec {
        case h264, h265
    }

    /// A decoded frame together with the time passed to `decode`.
    var onFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)?
    /// The decoder lost track (e.g. a missing reference frame) — a keyframe must be requested.
    var onDecodeError: ((OSStatus) -> Void)?
    /// Time to decode one frame (seconds).
    var onDecodeTime: ((CFTimeInterval) -> Void)?

    private let codec: Codec
    /// Output size when it should differ from the stream (the interpolator accepts only selected sizes).
    private let outputSize: (width: Int, height: Int)?

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var parametersChanged = false
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var payload: [UInt8] = []

    init(codec: Codec, outputSize: (width: Int, height: Int)? = nil) {
        self.codec = codec
        self.outputSize = outputSize
    }

    deinit { invalidate() }

    func invalidate() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    /// Accepts one sample: a header with parameter sets or an access unit.
    /// Returns `false` when the sample couldn't be passed to the decoder.
    func decode(_ bytes: UnsafeBufferPointer<UInt8>, time: CFTimeInterval) -> Bool {
        payload.removeAll(keepingCapacity: true)
        forEachNAL(in: bytes) { nal in
            guard let first = nal.first else { return }
            switch codec {
            case .h264:
                switch first & 0x1F {
                case 7: store(nal, in: &sps)
                case 8: store(nal, in: &pps)
                case 9, 12: break // access unit delimiter, filler
                default: appendLengthPrefixed(nal)
                }
            case .h265:
                switch (first >> 1) & 0x3F {
                case 32: store(nal, in: &vps)
                case 33: store(nal, in: &sps)
                case 34: store(nal, in: &pps)
                case 35, 38: break
                default: appendLengthPrefixed(nal)
                }
            }
        }

        if parametersChanged {
            parametersChanged = false
            guard rebuildFormat() else { return false }
        }
        // Header only — nothing to decode.
        guard !payload.isEmpty else { return true }
        guard let session, let format else { return false }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let blockBuffer,
            CMBlockBufferAssureBlockMemory(blockBuffer) == kCMBlockBufferNoErr,
            CMBlockBufferReplaceDataBytes(with: payload, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: payload.count) == kCMBlockBufferNoErr
        else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else { return false }

        let submitted = CACurrentMediaTime()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, presentationTime, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.onDecodeTime?(CACurrentMediaTime() - submitted)
                self.onFrame?(imageBuffer, presentationTime.seconds)
            } else if status != noErr {
                self.onDecodeError?(status)
            }
        }
        return status == noErr
    }

    // MARK: Annex B

    /// Calls `body` for each NAL unit (without the `00 00 01` start code).
    private func forEachNAL(in bytes: UnsafeBufferPointer<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let count = bytes.count
        var start = -1
        var index = 0

        func emit(until end: Int) {
            guard start >= 0 else { return }
            // Zeros before the next start code don't belong to the unit.
            var last = end
            while last > start, bytes[last - 1] == 0 { last -= 1 }
            if last > start {
                body(UnsafeBufferPointer(rebasing: bytes[start..<last]))
            }
        }

        while index + 2 < count {
            let third = bytes[index + 2]
            if third > 1 {
                index += 3
            } else if third == 1 {
                if bytes[index] == 0, bytes[index + 1] == 0 {
                    emit(until: index)
                    start = index + 3
                }
                index += 3
            } else {
                index += 1
            }
        }
        emit(until: count)
    }

    private func store(_ nal: UnsafeBufferPointer<UInt8>, in slot: inout [UInt8]?) {
        if let current = slot, current.count == nal.count, current.elementsEqual(nal) { return }
        slot = Array(nal)
        parametersChanged = true
    }

    private func appendLengthPrefixed(_ nal: UnsafeBufferPointer<UInt8>) {
        let length = UInt32(nal.count)
        payload.append(UInt8(truncatingIfNeeded: length >> 24))
        payload.append(UInt8(truncatingIfNeeded: length >> 16))
        payload.append(UInt8(truncatingIfNeeded: length >> 8))
        payload.append(UInt8(truncatingIfNeeded: length))
        payload.append(contentsOf: nal)
    }

    // MARK: Decoder session

    private func rebuildFormat() -> Bool {
        guard let sps, let pps else { return true } // wait for the full parameter set
        var sets: [[UInt8]] = [sps, pps]
        if codec == .h265 {
            guard let vps else { return true }
            sets = [vps, sps, pps]
        }

        var newFormat: CMVideoFormatDescription?
        let status: OSStatus = withParameterSetPointers(sets) { pointers, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return false }

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            format = newFormat
            return true
        }
        invalidate()

        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        if let outputSize {
            attributes[kCVPixelBufferWidthKey] = outputSize.width
            attributes[kCVPixelBufferHeightKey] = outputSize.height
        }
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession) == noErr,
            let newSession
        else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = newFormat
        return true
    }

    private func withParameterSetPointers(
        _ sets: [[UInt8]],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> OSStatus
    ) -> OSStatus {
        // Copies with stable addresses for the duration of the call.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!)
            }
        }
    }
}

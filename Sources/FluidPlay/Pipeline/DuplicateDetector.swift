import CoreVideo
import Foundation

/// Detects duplicate frames (a 30 fps game in a 60 fps stream).
///
/// Compares full luma with the last unique frame (every other row, vectorized 16 pixels at a time)
/// in 32×32 blocks. A duplicate frame isn't bit-identical after decoding — the encoder sends
/// small corrections spread across the whole image — so thresholds decide: a frame is new when
/// the whole image changes on average, or when even a single block changes clearly (a small moving object).
struct DuplicateDetector {
    /// Mean per-pixel difference over the whole image (levels 0–255) above which the frame is new.
    var globalThreshold = 0.8
    /// Mean difference within a single 32×32 block above which the frame is new.
    var blockThreshold = 5.0

    private var reference: [UInt8] = []
    private var referenceWidth = 0
    private var referenceHeight = 0
    private var blockSums: [UInt32] = []

    private static let block = 32
    private static let rowStep = 2

    mutating func reset() {
        referenceWidth = 0
        referenceHeight = 0
    }

    /// Returns `true` when the frame repeats the previous unique one. A unique frame becomes the new reference.
    mutating func isDuplicate(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        guard width >= Self.block, height >= Self.block else { return false }

        var duplicate = false
        if referenceWidth == width, referenceHeight == height {
            duplicate = reference.withUnsafeBufferPointer { compare(luma, stride: stride, reference: $0.baseAddress!, width: width, height: height) }
        }
        if !duplicate {
            if reference.count != width * height {
                reference = [UInt8](repeating: 0, count: width * height)
            }
            reference.withUnsafeMutableBufferPointer { destination in
                for row in 0..<height {
                    memcpy(destination.baseAddress! + row * width, luma + row * stride, width)
                }
            }
            referenceWidth = width
            referenceHeight = height
        }
        return duplicate
    }

    private mutating func compare(_ luma: UnsafePointer<UInt8>, stride: Int, reference: UnsafePointer<UInt8>,
                                  width: Int, height: Int) -> Bool {
        let block = Self.block
        let blocksX = (width + block - 1) / block
        if blockSums.count != blocksX { blockSums = [UInt32](repeating: 0, count: blocksX) }
        let vectorWidth = width / 16 * 16
        var total: UInt64 = 0
        var samples = 0

        var bandStart = 0
        while bandStart < height {
            let bandEnd = min(height, bandStart + block)
            for i in 0..<blocksX { blockSums[i] = 0 }
            var rowsInBand = 0
            var row = bandStart
            while row < bandEnd {
                let a = luma + row * stride
                let b = reference + row * width
                var x = 0
                while x < vectorWidth {
                    let va = UnsafeRawPointer(a + x).loadUnaligned(as: SIMD16<UInt8>.self)
                    let vb = UnsafeRawPointer(b + x).loadUnaligned(as: SIMD16<UInt8>.self)
                    let diff = pointwiseMax(va, vb) &- pointwiseMin(va, vb)
                    blockSums[x / block] &+= UInt32(SIMD16<UInt16>(truncatingIfNeeded: diff).wrappedSum())
                    x += 16
                }
                while x < width {
                    blockSums[x / block] &+= UInt32(abs(Int(a[x]) - Int(b[x])))
                    x += 1
                }
                rowsInBand += 1
                row += Self.rowStep
            }
            // A clear change in one block is enough — stop counting.
            for i in 0..<blocksX {
                let blockWidth = min(block, width - i * block)
                let mean = Double(blockSums[i]) / Double(blockWidth * rowsInBand)
                if mean > blockThreshold { return false }
                total += UInt64(blockSums[i])
            }
            samples += width * rowsInBand
            bandStart = bandEnd
        }
        return Double(total) / Double(max(samples, 1)) < globalThreshold
    }
}

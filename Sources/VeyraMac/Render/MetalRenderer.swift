import CoreVideo
import Foundation
import Metal
import MetalFX
import QuartzCore

struct RenderSettings: Equatable {
    /// Scaling to the display size via MetalFX Spatial instead of bilinear filtering.
    var metalFX = true
    /// 0…1
    var sharpness: Float = 0.25
}

/// GPU resources shared by all views.
final class RenderCore {
    /// The shared instance, or `nil` when Metal or the shaders are unavailable (reason in `startupError`).
    static let shared: RenderCore? = {
        do {
            return try RenderCore()
        } catch {
            startupError = error.localizedDescription
            return nil
        }
    }()
    private(set) static var startupError: String?

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let convertPipeline: MTLRenderPipelineState
    let presentPipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ProcessorError.unsupported(String(localized: "Metal isn't available."))
        }
        self.device = device
        self.commandQueue = queue
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vs_fullscreen")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        convertPipeline = try pipeline("fs_convert")
        presentPipeline = try pipeline("fs_present")

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw ProcessorError.unsupported(String(localized: "Couldn't create the texture cache.")) }
        textureCache = cache
    }
}

/// Draws NV12 frames into the target texture: color conversion → MetalFX Spatial → composite with sharpening.
final class MetalRenderer {
    let core: RenderCore
    let settings = Locked(RenderSettings())

    private var colorTexture: MTLTexture?
    private var scaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = ""
    /// Whether the last frame went through MetalFX (for stats).
    private(set) var usedMetalFX = false

    init(core: RenderCore) {
        self.core = core
    }

    /// Encodes drawing the image area of `frame` into `target`. Returns `false` when the frame can't be drawn.
    @discardableResult
    func encode(frame: VideoFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let pixelBuffer = frame.pixelBuffer
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        // From here on we work only on the image area (without the canvas background).
        let width = min(max(frame.contentWidth, 2), bufferWidth)
        let height = min(max(frame.contentHeight, 2), bufferHeight)
        guard bufferWidth > 0, bufferHeight > 0, target.width > 0, target.height > 0,
              let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }

        let settings = settings.get()

        // Rectangle fitted into the target preserving aspect ratio.
        let fit = min(Double(target.width) / Double(width), Double(target.height) / Double(height))
        let fitWidth = max(1, min(target.width, Int((Double(width) * fit).rounded())))
        let fitHeight = max(1, min(target.height, Int((Double(height) * fit).rounded())))
        let originX = (target.width - fitWidth) / 2
        let originY = (target.height - fitHeight) / 2

        let wantScaler = settings.metalFX && fitWidth > width && fitHeight > height
        let activeScaler = wantScaler ? prepareScaler(inputWidth: width, inputHeight: height, outputWidth: fitWidth, outputHeight: fitHeight) : nil
        if !wantScaler { releaseScaler() }
        usedMetalFX = activeScaler != nil

        guard let colorTexture = prepareColorTexture(width: width, height: height, extraUsage: activeScaler?.colorTextureUsage ?? []) else {
            return false
        }

        // 1. NV12 -> RGB at source resolution.
        let convertPass = MTLRenderPassDescriptor()
        convertPass.colorAttachments[0].texture = colorTexture
        convertPass.colorAttachments[0].loadAction = .dontCare
        convertPass.colorAttachments[0].storeAction = .store
        guard let convert = commandBuffer.makeRenderCommandEncoder(descriptor: convertPass) else { return false }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let scaleX = Float(width) / Float(bufferWidth)
        let scaleY = Float(height) / Float(bufferHeight)
        var convertUniforms: [SIMD4<Float>] = [
            SIMD4(format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0, 0, scaleX, scaleY),
            SIMD4(scaleX - 1 / Float(bufferWidth), scaleY - 1 / Float(bufferHeight), 0, 0),
        ]
        convert.setRenderPipelineState(core.convertPipeline)
        convert.setFragmentTexture(lumaTexture, index: 0)
        convert.setFragmentTexture(chromaTexture, index: 1)
        convert.setFragmentBytes(&convertUniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        convert.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        convert.endEncoding()

        // 2. MetalFX spatial scaling to the target size.
        var presentSource = colorTexture
        if let activeScaler, let scaledTexture {
            activeScaler.colorTexture = colorTexture
            activeScaler.outputTexture = scaledTexture
            activeScaler.inputContentWidth = width
            activeScaler.inputContentHeight = height
            activeScaler.encode(commandBuffer: commandBuffer)
            presentSource = scaledTexture
        }

        // 3. Composite into the target with sharpening.
        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = target
        presentPass.colorAttachments[0].loadAction = .clear
        presentPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        presentPass.colorAttachments[0].storeAction = .store
        guard let present = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) else { return false }
        var presentUniforms = SIMD4<Float>(1 / Float(presentSource.width), 1 / Float(presentSource.height), settings.sharpness, 0)
        present.setRenderPipelineState(core.presentPipeline)
        present.setViewport(MTLViewport(originX: Double(originX), originY: Double(originY),
                                        width: Double(fitWidth), height: Double(fitHeight), znear: 0, zfar: 1))
        present.setFragmentTexture(presentSource, index: 0)
        present.setFragmentBytes(&presentUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        present.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        present.endEncoding()

        // CoreVideo textures must stay alive until the command buffer finishes executing.
        commandBuffer.addCompletedHandler { _ in
            _ = luma
            _ = chroma
        }
        return true
    }

    /// Clears the target to black (no frame).
    func encodeClear(into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, core.textureCache, pixelBuffer, nil, format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            plane, &texture)
        return texture
    }

    private func prepareColorTexture(width: Int, height: Int, extraUsage: MTLTextureUsage) -> MTLTexture? {
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead, extraUsage]
        if let colorTexture, colorTexture.width == width, colorTexture.height == height, colorTexture.usage.contains(usage) {
            return colorTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderCore.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        colorTexture = core.device.makeTexture(descriptor: descriptor)
        return colorTexture
    }

    private func prepareScaler(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> MTLFXSpatialScaler? {
        let key = "\(inputWidth)x\(inputHeight)>\(outputWidth)x\(outputHeight)"
        if key == scalerKey { return scaler }
        scalerKey = key
        scaler = nil
        scaledTexture = nil
        guard MTLFXSpatialScalerDescriptor.supportsDevice(core.device) else { return nil }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = RenderCore.pixelFormat
        descriptor.outputTextureFormat = RenderCore.pixelFormat
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: core.device) else { return nil }

        let output = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderCore.pixelFormat, width: outputWidth, height: outputHeight, mipmapped: false)
        output.usage = [.shaderRead, scaler.outputTextureUsage]
        output.storageMode = .private
        guard let texture = core.device.makeTexture(descriptor: output) else { return nil }
        self.scaler = scaler
        self.scaledTexture = texture
        return scaler
    }

    private func releaseScaler() {
        guard scaler != nil || !scalerKey.isEmpty else { return }
        scaler = nil
        scaledTexture = nil
        scalerKey = ""
    }
}

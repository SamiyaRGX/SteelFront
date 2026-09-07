//
//  MetalRenderer.swift
//  SteelFront
//
//  The whole frame: procedural sky, lit level geometry, animated enemies, the
//  first person weapon, the additive/alpha effect layer, then a bloom and
//  tonemap composite into the drawable.
//

import Foundation
import Metal
import MetalKit
import simd

struct SceneLight {
    var position = SIMD3<Float>(repeating: 0)
    var colour = SIMD3<Float>(repeating: 0)
    var radius: Float = 0
}

struct RenderFrame {
    var viewMatrix = matrix_identity_float4x4
    var projMatrix = matrix_identity_float4x4
    var viewModelProj = matrix_identity_float4x4
    var cameraPosition = SIMD3<Float>(repeating: 0)
    var fovScale: Float = 1
    var sunDirection = SIMD4<Float>(0.4, 0.8, 0.3, 1.6)
    var sunColour = SIMD4<Float>(1.0, 0.92, 0.78, 1)
    var skyColour = SIMD4<Float>(0.45, 0.55, 0.70, 0.35)
    var fog = SIMD4<Float>(0.62, 0.60, 0.55, 0.004)
    var lights: [SceneLight] = []
    /// x time, y exposure, z damage flash, w hit marker
    var params = SIMD4<Float>(0, 1.1, 0, 0)
    var levelDraws: [SceneDraw] = []
    var enemyDraws: [SceneDraw] = []
    var viewModelDraws: [SceneDraw] = []
    var fxBatch = ParticleSystem.Batch()
    var atlas: MTLTexture?
    var spriteSheet: MTLTexture?
}

final class MetalRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue

    private let skyPipeline: MTLRenderPipelineState
    private let litPipeline: MTLRenderPipelineState
    private let enemyPipeline: MTLRenderPipelineState
    private let viewModelPipeline: MTLRenderPipelineState
    private let fxAdditivePipeline: MTLRenderPipelineState
    private let fxAlphaPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private let depthWrite: MTLDepthStencilState
    private let depthReadOnly: MTLDepthStencilState
    private let depthAlways: MTLDepthStencilState

    private var sceneTexture: MTLTexture?
    private var msaaTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var textureSize = CGSize.zero
    private var sampleCount = 1

    private let uniformScratch = UnsafeMutableRawPointer.allocate(byteCount: FrameOffsets.size,
                                                                  alignment: 16)
    private let drawScratch = UnsafeMutableRawPointer.allocate(byteCount: DrawOffsets.size,
                                                               alignment: 16)

    private(set) var lastFrameDrawCalls = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let skyFunction = library.makeFunction(name: "skyVertex"),
              let skyFragment = library.makeFunction(name: "skyFragment"),
              let litVertex = library.makeFunction(name: "litVertex"),
              let litFragment = library.makeFunction(name: "litFragment"),
              let enemyVertex = library.makeFunction(name: "enemyVertex"),
              let viewModelVertex = library.makeFunction(name: "viewModelVertex"),
              let fxVertex = library.makeFunction(name: "fxVertex"),
              let fxFragment = library.makeFunction(name: "fxFragment"),
              let postVertex = library.makeFunction(name: "postVertex"),
              let brightFragment = library.makeFunction(name: "brightFragment"),
              let blurFragment = library.makeFunction(name: "blurFragment"),
              let compositeFragment = library.makeFunction(name: "compositeFragment")
        else { return nil }
        self.queue = queue

        let sceneDescriptor = VertexLayout.sceneDescriptor()
        let fxDescriptor = VertexLayout.fxDescriptor()

        // --- Sky ---------------------------------------------------------------
        let sky = MTLRenderPipelineDescriptor()
        sky.vertexFunction = skyFunction
        sky.fragmentFunction = skyFragment
        sky.rasterSampleCount = 1
        sky.colorAttachments[0].pixelFormat = .rgba16Float
        sky.depthAttachmentPixelFormat = .depth32Float

        // --- Lit geometry --------------------------------------------------------
        let lit = MTLRenderPipelineDescriptor()
        lit.vertexFunction = litVertex
        lit.fragmentFunction = litFragment
        lit.vertexDescriptor = sceneDescriptor
        lit.colorAttachments[0].pixelFormat = .rgba16Float
        lit.depthAttachmentPixelFormat = .depth32Float

        // --- Enemies -------------------------------------------------------------
        let enemy = MTLRenderPipelineDescriptor()
        enemy.vertexFunction = enemyVertex
        enemy.fragmentFunction = litFragment
        enemy.vertexDescriptor = sceneDescriptor
        enemy.colorAttachments[0].pixelFormat = .rgba16Float
        enemy.depthAttachmentPixelFormat = .depth32Float

        // --- View model -----------------------------------------------------------
        let viewModel = MTLRenderPipelineDescriptor()
        viewModel.vertexFunction = viewModelVertex
        viewModel.fragmentFunction = litFragment
        viewModel.vertexDescriptor = sceneDescriptor
        viewModel.colorAttachments[0].pixelFormat = .rgba16Float
        viewModel.depthAttachmentPixelFormat = .depth32Float

        // --- Effects ---------------------------------------------------------------
        let fxAdditive = MTLRenderPipelineDescriptor()
        fxAdditive.vertexFunction = fxVertex
        fxAdditive.fragmentFunction = fxFragment
        fxAdditive.vertexDescriptor = fxDescriptor
        fxAdditive.colorAttachments[0].pixelFormat = .rgba16Float
        fxAdditive.colorAttachments[0].isBlendingEnabled = true
        fxAdditive.colorAttachments[0].rgbBlendOperation = .add
        fxAdditive.colorAttachments[0].alphaBlendOperation = .add
        fxAdditive.colorAttachments[0].sourceRGBBlendFactor = .one
        fxAdditive.colorAttachments[0].sourceAlphaBlendFactor = .one
        fxAdditive.colorAttachments[0].destinationRGBBlendFactor = .one
        fxAdditive.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        fxAdditive.depthAttachmentPixelFormat = .depth32Float

        let fxAlpha = MTLRenderPipelineDescriptor()
        fxAlpha.vertexFunction = fxVertex
        fxAlpha.fragmentFunction = fxFragment
        fxAlpha.vertexDescriptor = fxDescriptor
        fxAlpha.colorAttachments[0].pixelFormat = .rgba16Float
        fxAlpha.colorAttachments[0].isBlendingEnabled = true
        fxAlpha.colorAttachments[0].rgbBlendOperation = .add
        fxAlpha.colorAttachments[0].alphaBlendOperation = .add
        fxAlpha.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        fxAlpha.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        fxAlpha.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        fxAlpha.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        fxAlpha.depthAttachmentPixelFormat = .depth32Float

        // --- Post --------------------------------------------------------------------
        let bright = MTLRenderPipelineDescriptor()
        bright.vertexFunction = postVertex
        bright.fragmentFunction = brightFragment
        bright.colorAttachments[0].pixelFormat = .rgba16Float

        let blur = MTLRenderPipelineDescriptor()
        blur.vertexFunction = postVertex
        blur.fragmentFunction = blurFragment
        blur.colorAttachments[0].pixelFormat = .rgba16Float

        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = postVertex
        composite.fragmentFunction = compositeFragment
        composite.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            skyPipeline = try device.makeRenderPipelineState(descriptor: sky)
            litPipeline = try device.makeRenderPipelineState(descriptor: lit)
            enemyPipeline = try device.makeRenderPipelineState(descriptor: enemy)
            viewModelPipeline = try device.makeRenderPipelineState(descriptor: viewModel)
            fxAdditivePipeline = try device.makeRenderPipelineState(descriptor: fxAdditive)
            fxAlphaPipeline = try device.makeRenderPipelineState(descriptor: fxAlpha)
            brightPipeline = try device.makeRenderPipelineState(descriptor: bright)
            blurPipeline = try device.makeRenderPipelineState(descriptor: blur)
            compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        } catch {
            return nil
        }

        let writeDescriptor = MTLDepthStencilDescriptor()
        writeDescriptor.depthCompareFunction = .less
        writeDescriptor.isDepthWriteEnabled = true
        let readDescriptor = MTLDepthStencilDescriptor()
        readDescriptor.depthCompareFunction = .less
        readDescriptor.isDepthWriteEnabled = false
        let alwaysDescriptor = MTLDepthStencilDescriptor()
        alwaysDescriptor.depthCompareFunction = .always
        alwaysDescriptor.isDepthWriteEnabled = false

        guard let write = device.makeDepthStencilState(descriptor: writeDescriptor),
              let read = device.makeDepthStencilState(descriptor: readDescriptor),
              let always = device.makeDepthStencilState(descriptor: alwaysDescriptor) else { return nil }
        depthWrite = write
        depthReadOnly = read
        depthAlways = always
    }

    deinit {
        uniformScratch.deallocate()
        drawScratch.deallocate()
    }

    // MARK: - Targets

    func prepareTargets(size: CGSize, view: MTKView) {
        let pixelWidth = max(1, Int(size.width))
        let pixelHeight = max(1, Int(size.height))
        if textureSize.width == CGFloat(pixelWidth), textureSize.height == CGFloat(pixelHeight),
           sceneTexture != nil {
            return
        }
        textureSize = CGSize(width: pixelWidth, height: pixelHeight)

        // Every scene pipeline is created with rasterSampleCount = 1, so the
        // scene framebuffer must not be multisampled. MTKView defaults to 4x
        // MSAA, which caused undefined (glitched) rendering on device.
        _ = view
        sampleCount = 1

        let colour = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                              width: pixelWidth,
                                                              height: pixelHeight,
                                                              mipmapped: false)
        colour.usage = [.renderTarget, .shaderRead]
        colour.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: colour)

        if sampleCount > 1 {
            let msaa = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                width: pixelWidth,
                                                                height: pixelHeight,
                                                                mipmapped: false)
            msaa.textureType = .type2DMultisample
            msaa.sampleCount = sampleCount
            msaa.usage = .renderTarget
            msaa.storageMode = .private
            msaaTexture = device.makeTexture(descriptor: msaa)
        } else {
            msaaTexture = nil
        }

        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                             width: pixelWidth,
                                                             height: pixelHeight,
                                                             mipmapped: false)
        depth.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        depth.sampleCount = sampleCount
        depth.usage = .renderTarget
        depth.storageMode = .private
        depthTexture = device.makeTexture(descriptor: depth)

        let bloomWidth = max(1, pixelWidth / 2)
        let bloomHeight = max(1, pixelHeight / 2)
        let bloom = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: bloomWidth, height: bloomHeight,
                                                             mipmapped: false)
        bloom.usage = [.renderTarget, .shaderRead]
        bloom.storageMode = .private
        bloomA = device.makeTexture(descriptor: bloom)
        bloomB = device.makeTexture(descriptor: bloom)
    }

    // MARK: - Frame

    func render(frame: RenderFrame, view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let sceneTarget = sceneTexture else { return }

        lastFrameDrawCalls = 0
        let sourceTexture = msaaTexture ?? sceneTarget
        encodeScene(frame: frame, target: sourceTexture, resolve: msaaTexture != nil ? sceneTarget : nil,
                    commandBuffer: commandBuffer, view: view)
        encodePost(frame: frame, scene: sceneTarget, drawable: drawable,
                   commandBuffer: commandBuffer, view: view)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Scene pass

    private func encodeScene(frame: RenderFrame, target: MTLTexture, resolve: MTLTexture?,
                             commandBuffer: MTLCommandBuffer, view: MTKView) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.45, green: 0.48, blue: 0.52, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        if let resolve {
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(textureSize.width),
                                        height: Double(textureSize.height),
                                        znear: 0, zfar: 1))

        writeFrameUniforms(frame)
        encoder.setVertexBytes(uniformScratch, length: FrameOffsets.size, index: 0)
        encoder.setFragmentBytes(uniformScratch, length: FrameOffsets.size, index: 0)
        if let atlas = frame.atlas {
            encoder.setFragmentTexture(atlas, index: 0)
        }

        // --- Sky ---
        encoder.setRenderPipelineState(skyPipeline)
        encoder.setDepthStencilState(depthAlways)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        lastFrameDrawCalls += 1

        // --- Level ---
        encoder.setRenderPipelineState(litPipeline)
        encoder.setDepthStencilState(depthWrite)
        for draw in frame.levelDraws {
            encode(draw: draw, encoder: encoder)
        }

        // --- Enemies ---
        encoder.setRenderPipelineState(enemyPipeline)
        for draw in frame.enemyDraws {
            encode(draw: draw, encoder: encoder)
        }

        // --- First person weapon ---
        if !frame.viewModelDraws.isEmpty {
            encoder.setRenderPipelineState(viewModelPipeline)
            encoder.setDepthStencilState(depthAlways)
            encoder.setCullMode(.none)
            writeViewModelUniforms(frame)
            encoder.setVertexBytes(uniformScratch, length: FrameOffsets.size, index: 0)
            for draw in frame.viewModelDraws {
                encode(draw: draw, encoder: encoder)
            }
            encoder.setCullMode(.back)
            writeFrameUniforms(frame)
            encoder.setVertexBytes(uniformScratch, length: FrameOffsets.size, index: 0)
            encoder.setFragmentBytes(uniformScratch, length: FrameOffsets.size, index: 0)
        }

        // --- Effects ---
        if let sprite = frame.spriteSheet {
            encoder.setFragmentTexture(sprite, index: 0)
            encoder.setDepthStencilState(depthReadOnly)
            if let alpha = frame.fxBatch.alpha, frame.fxBatch.alphaCount > 0 {
                encoder.setRenderPipelineState(fxAlphaPipeline)
                encoder.setVertexBuffer(alpha, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: frame.fxBatch.alphaCount)
                lastFrameDrawCalls += 1
            }
            if let additive = frame.fxBatch.additive, frame.fxBatch.additiveCount > 0 {
                encoder.setRenderPipelineState(fxAdditivePipeline)
                encoder.setVertexBuffer(additive, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: frame.fxBatch.additiveCount)
                lastFrameDrawCalls += 1
            }
        }
        encoder.endEncoding()
    }

    private func encode(draw: SceneDraw, encoder: MTLRenderCommandEncoder) {
        let writer = UniformWriter(drawScratch)
        writer.mat4(DrawOffsets.model, draw.model)
        writer.vec4(DrawOffsets.tint, draw.tint)
        writer.vec4(DrawOffsets.params, draw.params)
        writer.vec4(DrawOffsets.anim, draw.anim)
        writer.vec4(DrawOffsets.extra, draw.extra)
        encoder.setVertexBytes(drawScratch, length: DrawOffsets.size, index: 1)
        encoder.setFragmentBytes(drawScratch, length: DrawOffsets.size, index: 1)
        draw.mesh.draw(encoder)
        lastFrameDrawCalls += 1
    }

    // MARK: - Post pass

    private func encodePost(frame: RenderFrame, scene: MTLTexture, drawable: CAMetalDrawable,
                            commandBuffer: MTLCommandBuffer, view: MTKView) {
        guard let bloomA, let bloomB else { return }

        // Bright pass.
        if let encoder = makeFullScreenEncoder(target: bloomA, commandBuffer: commandBuffer) {
            encoder.setRenderPipelineState(brightPipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Separable blur, two iterations for a wider glow.
        let texelWidth = 1.0 / Float(max(1, bloomA.width))
        let texelHeight = 1.0 / Float(max(1, bloomA.height))
        for _ in 0..<2 {
            var direction = SIMD2<Float>(texelWidth, 0)
            if let encoder = makeFullScreenEncoder(target: bloomB, commandBuffer: commandBuffer) {
                encoder.setRenderPipelineState(blurPipeline)
                encoder.setFragmentTexture(bloomA, index: 0)
                encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            direction = SIMD2<Float>(0, texelHeight)
            if let encoder = makeFullScreenEncoder(target: bloomA, commandBuffer: commandBuffer) {
                encoder.setRenderPipelineState(blurPipeline)
                encoder.setFragmentTexture(bloomB, index: 0)
                encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        // Composite.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Metal starts every encoder with a 0x0 viewport: without this the
        // composite rasterises nothing and the screen shows uninitialised
        // drawable memory (full screen static noise).
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(drawable.texture.width),
                                        height: Double(drawable.texture.height),
                                        znear: 0, zfar: 1))
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(bloomA, index: 1)
        writeFrameUniforms(frame)
        encoder.setFragmentBytes(uniformScratch, length: FrameOffsets.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeFullScreenEncoder(target: MTLTexture,
                                       commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(target.width), height: Double(target.height),
                                        znear: 0, zfar: 1))
        return encoder
    }

    // MARK: - Uniform packing

    private func writeFrameUniforms(_ frame: RenderFrame) {
        let writer = UniformWriter(uniformScratch)
        writer.mat4(FrameOffsets.viewProj, frame.projMatrix * frame.viewMatrix)
        let inverse = (frame.projMatrix * frame.viewMatrix).inverse
        writer.mat4(FrameOffsets.invViewProj, inverse)
        writer.vec4(FrameOffsets.cameraPos, SIMD4(frame.cameraPosition, frame.fovScale))
        writer.vec4(FrameOffsets.sunDir, frame.sunDirection)
        writer.vec4(FrameOffsets.sunColor, frame.sunColour)
        writer.vec4(FrameOffsets.skyColor, frame.skyColour)
        writer.vec4(FrameOffsets.fogParams, frame.fog)
        for index in 0..<4 {
            if index < frame.lights.count {
                let light = frame.lights[index]
                writer.vec4(FrameOffsets.lightPos[index], SIMD4(light.position, light.radius))
                writer.vec4(FrameOffsets.lightCol[index], SIMD4(light.colour, 1))
            } else {
                writer.vec4(FrameOffsets.lightPos[index], SIMD4(0, 0, 0, 0))
                writer.vec4(FrameOffsets.lightCol[index], SIMD4(0, 0, 0, 0))
            }
        }
        writer.vec4(FrameOffsets.params, frame.params)
    }

    private func writeViewModelUniforms(_ frame: RenderFrame) {
        let writer = UniformWriter(uniformScratch)
        writer.mat4(FrameOffsets.viewProj, frame.viewModelProj)
        writer.mat4(FrameOffsets.invViewProj, frame.viewModelProj.inverse)
        writer.vec4(FrameOffsets.cameraPos, SIMD4(SIMD3<Float>(repeating: 0), 1))
        writer.vec4(FrameOffsets.sunDir, SIMD4(0.3, 0.85, 0.45, 1.5))
        writer.vec4(FrameOffsets.sunColor, frame.sunColour)
        writer.vec4(FrameOffsets.skyColor, SIMD4(0.55, 0.58, 0.62, 0.6))
        writer.vec4(FrameOffsets.fogParams, SIMD4(0, 0, 0, 0))
        for index in 0..<4 {
            writer.vec4(FrameOffsets.lightPos[index], SIMD4(0, 0, 0, 0))
            writer.vec4(FrameOffsets.lightCol[index], SIMD4(0, 0, 0, 0))
        }
        // Muzzle flash lights the gun from the front.
        writer.vec4(FrameOffsets.lightPos[0], SIMD4(0.15, -0.1, -1.2, 3.0))
        writer.vec4(FrameOffsets.lightCol[0], SIMD4(6.0 * frame.params.w, 4.4 * frame.params.w,
                                                    2.6 * frame.params.w, 1))
        writer.vec4(FrameOffsets.params, SIMD4(frame.params.x, 1.15, 0, 0))
    }
}

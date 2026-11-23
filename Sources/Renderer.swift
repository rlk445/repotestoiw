import MetalKit
import simd
import QuartzCore

struct FrameUniforms {
    var viewProj: simd_float4x4
}

struct DrawUniforms {
    var model: simd_float4x4
}

struct HandVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

private let boneLinks: [(Int, Int)] = [
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12),
    (9, 13), (13, 14), (14, 15), (15, 16),
    (13, 17), (17, 18), (18, 19), (19, 20),
    (0, 17)
]

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let model: AppModel
    private let scene: LoadedScene
    private var textures: [MTLTexture?] = []
    private let fallback: MTLTexture
    private let psoScene: MTLRenderPipelineState
    private let psoHand: MTLRenderPipelineState
    private let dsScene: MTLDepthStencilState
    private let dsOff: MTLDepthStencilState
    private let sampler: MTLSamplerState

    private var aspect: Float = 0.5
    private let eye = SIMD3<Float>(0, 1.6, 0)
    private let fovY: Float = 65.0 * Float.pi / 180.0

    var yawOffset: Float = 0
    var pitchOffset: Float = 0

    private var pinchWas: [String: Bool] = [:]
    private var pinchPrev: [String: SIMD2<Float>] = [:]

    static var lastError = ""
    var summary: String {
        let ok = textures.filter { $0 != nil }.count
        return "cena ok: \(scene.draws.count) draws, \(ok)/\(textures.count) texturas"
    }

    init?(view: MTKView, model: AppModel) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            Renderer.lastError = "sem GPU Metal"
            return nil
        }
        guard let library = dev.makeDefaultLibrary() else {
            Renderer.lastError = "shaders nao encontrados"
            return nil
        }
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.62, green: 0.74, blue: 0.9, alpha: 1)
        view.preferredFramesPerSecond = 60

        let loaded: LoadedScene
        do {
            loaded = try SceneLoader.load(device: dev, name: "desert")
        } catch {
            Renderer.lastError = "scene.bin: \(error)"
            return nil
        }

        // vertex: pos float3 + uv float2 = 20 bytes
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 20
        vd.layouts[0].stepFunction = .perVertex

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = library.makeFunction(name: "scene_vertex")
        sd.fragmentFunction = library.makeFunction(name: "scene_fragment")
        sd.vertexDescriptor = vd
        sd.rasterSampleCount = view.sampleCount
        sd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        sd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let sceneState: MTLRenderPipelineState
        do { sceneState = try dev.makeRenderPipelineState(descriptor: sd) } catch {
            Renderer.lastError = "pipeline cena: \(error.localizedDescription)"
            return nil
        }

        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = library.makeFunction(name: "hand_vertex")
        hd.fragmentFunction = library.makeFunction(name: "hand_fragment")
        hd.rasterSampleCount = view.sampleCount
        hd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let ca = hd.colorAttachments[0]!
        ca.pixelFormat = view.colorPixelFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let handState: MTLRenderPipelineState
        do { handState = try dev.makeRenderPipelineState(descriptor: hd) } catch {
            Renderer.lastError = "pipeline maos: \(error.localizedDescription)"
            return nil
        }

        let d1 = MTLDepthStencilDescriptor()
        d1.depthCompareFunction = .less
        d1.isDepthWriteEnabled = true
        let d2 = MTLDepthStencilDescriptor()
        d2.depthCompareFunction = .always
        d2.isDepthWriteEnabled = false
        guard let ds1 = dev.makeDepthStencilState(descriptor: d1),
              let ds2 = dev.makeDepthStencilState(descriptor: d2) else { return nil }

        let sampd = MTLSamplerDescriptor()
        sampd.minFilter = .linear
        sampd.magFilter = .linear
        sampd.mipFilter = .linear
        sampd.sAddressMode = .repeat
        sampd.tAddressMode = .repeat
        sampd.maxAnisotropy = 4
        guard let samp = dev.makeSamplerState(descriptor: sampd) else { return nil }

        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let fb = dev.makeTexture(descriptor: fd) else { return nil }
        var white: [UInt8] = [200, 200, 200, 255]
        fb.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)

        var texs: [MTLTexture?] = []
        for name in loaded.textureNames {
            let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "desert")
            if let url = url {
                texs.append(KTXLoader.load(url: url, device: dev))
            } else {
                texs.append(nil)
            }
        }

        self.device = dev
        self.queue = q
        self.model = model
        self.scene = loaded
        self.textures = texs
        self.fallback = fb
        self.psoScene = sceneState
        self.psoHand = handState
        self.dsScene = ds1
        self.dsOff = ds2
        self.sampler = samp
        super.init()
    }

    // MARK: - interação

    func addLook(yaw: Float, pitch: Float) {
        yawOffset += yaw
        pitchOffset = max(-1.4, min(1.4, pitchOffset + pitch))
    }

    func recenter() {
        yawOffset = 0
        pitchOffset = 0
        model.motion.recenter()
    }

    private func updateInteraction(_ hands: [TrackedHand]) {
        var seen = Set<String>()
        for h in hands {
            seen.insert(h.label)
            let was = pinchWas[h.label] ?? false
            if h.pinching {
                if !was {
                    model.audio.play("sfx_grab")
                } else if let prev = pinchPrev[h.label] {
                    let dx = h.pinchPoint.x - prev.x
                    let dy = h.pinchPoint.y - prev.y
                    // arrastar a cena: mão para a direita gira a câmera para a esquerda
                    addLook(yaw: dx * 3.2, pitch: dy * 2.4)
                }
                pinchPrev[h.label] = h.pinchPoint
            } else {
                if was { model.audio.play("sfx_release_main") }
                pinchPrev.removeValue(forKey: h.label)
            }
            pinchWas[h.label] = h.pinching
        }
        for k in pinchWas.keys where !seen.contains(k) {
            pinchWas.removeValue(forKey: k)
            pinchPrev.removeValue(forKey: k)
        }
    }

    // MARK: - mãos no espaço da câmera

    private func handViewPoint(_ l: SIMD3<Float>) -> SIMD3<Float> {
        let d: Float = 0.45
        let s = 2 * d * tan(fovY * 0.5)
        let x = (l.x - 0.5) * cameraAspect * s
        let y = (0.5 - l.y) * s
        let z = -d - l.z * cameraAspect * s
        return SIMD3<Float>(x, y, z)
    }

    private func quad(_ out: inout [HandVertex], center c: SIMD3<Float>, half r: Float, color: SIMD4<Float>) {
        let a = SIMD4<Float>(c.x - r, c.y - r, c.z, 1)
        let b = SIMD4<Float>(c.x + r, c.y - r, c.z, 1)
        let cc = SIMD4<Float>(c.x + r, c.y + r, c.z, 1)
        let d = SIMD4<Float>(c.x - r, c.y + r, c.z, 1)
        out.append(HandVertex(position: a, color: color))
        out.append(HandVertex(position: b, color: color))
        out.append(HandVertex(position: cc, color: color))
        out.append(HandVertex(position: a, color: color))
        out.append(HandVertex(position: cc, color: color))
        out.append(HandVertex(position: d, color: color))
    }

    private func bone(_ out: inout [HandVertex], from a: SIMD3<Float>, to b: SIMD3<Float>, width w: Float, color: SIMD4<Float>) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        if len < 1e-5 { return }
        let px = -dy / len * w
        let py = dx / len * w
        let p0 = SIMD4<Float>(a.x + px, a.y + py, a.z, 1)
        let p1 = SIMD4<Float>(a.x - px, a.y - py, a.z, 1)
        let p2 = SIMD4<Float>(b.x - px, b.y - py, b.z, 1)
        let p3 = SIMD4<Float>(b.x + px, b.y + py, b.z, 1)
        out.append(HandVertex(position: p0, color: color))
        out.append(HandVertex(position: p1, color: color))
        out.append(HandVertex(position: p2, color: color))
        out.append(HandVertex(position: p0, color: color))
        out.append(HandVertex(position: p2, color: color))
        out.append(HandVertex(position: p3, color: color))
    }

    private func buildHandVertices(_ hands: [TrackedHand]) -> [HandVertex] {
        var out: [HandVertex] = []
        out.reserveCapacity(hands.count * 260)
        for h in hands {
            let base: SIMD4<Float> = h.label == "Left"
                ? SIMD4<Float>(0.25, 0.85, 1.0, 0.9)
                : SIMD4<Float>(1.0, 0.45, 0.85, 0.9)
            let joint: SIMD4<Float> = h.pinching ? SIMD4<Float>(1.0, 0.85, 0.2, 1.0) : SIMD4<Float>(1, 1, 1, 1)
            let pts = h.points.map { handViewPoint($0) }
            for (a, b) in boneLinks {
                bone(&out, from: pts[a], to: pts[b], width: 0.0022, color: base)
            }
            for (i, p) in pts.enumerated() {
                let tip = (i == 4 || i == 8 || i == 12 || i == 16 || i == 20)
                quad(&out, center: p, half: tip ? 0.0048 : 0.0033, color: joint)
            }
        }
        return out
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 {
            aspect = Float(size.width / size.height)
        }
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        if view.drawableSize.height > 0 {
            aspect = Float(view.drawableSize.width / view.drawableSize.height)
        }

        let hands = model.tracker.currentHands()
        updateInteraction(hands)

        let camRot = rotationY(yawOffset) * model.motion.rotation() * rotationX(pitchOffset)
        let viewM = simd_float4x4(rotation: camRot.transpose) * simd_float4x4.translation(-eye)
        let proj = simd_float4x4.perspective(fovY: fovY, aspect: aspect, near: 0.05, far: 4000)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setCullMode(.none)

        // cena
        enc.setRenderPipelineState(psoScene)
        enc.setDepthStencilState(dsScene)
        var fu = FrameUniforms(viewProj: proj * viewM)
        enc.setVertexBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)

        for d in scene.draws {
            let mesh = scene.meshes[d.mesh]
            var du = DrawUniforms(model: d.world)
            enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            var tex: MTLTexture = fallback
            if mesh.material >= 0 && mesh.material < scene.materials.count {
                let ti = scene.materials[mesh.material].texture
                if ti >= 0 && ti < textures.count, let t = textures[ti] {
                    tex = t
                }
            }
            enc.setFragmentTexture(tex, index: 0)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
        }

        // mãos
        let hv = buildHandVertices(hands)
        if !hv.isEmpty {
            let length = hv.count * MemoryLayout<HandVertex>.stride
            if let buf = device.makeBuffer(bytes: hv, length: length, options: .storageModeShared) {
                enc.setRenderPipelineState(psoHand)
                enc.setDepthStencilState(dsOff)
                var hp = proj
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&hp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: hv.count)
            }
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.addCompletedHandler { [weak self] c in
            if let e = c.error {
                DispatchQueue.main.async { self?.model.renderInfo = "GPU erro: \(e.localizedDescription)" }
            }
        }
        cb.commit()
    }
}

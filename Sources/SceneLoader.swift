import Metal
import simd
import Foundation

enum SceneError: Error {
    case missing
    case badMagic
    case truncated
}

struct MeshGPU {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let material: Int
}

struct MaterialInfo {
    let texture: Int
    let blend: Bool
    let tint: SIMD4<Float>
}

struct SceneDraw {
    let mesh: Int
    let world: simd_float4x4
}

final class LoadedScene {
    var meshes: [MeshGPU] = []
    var materials: [MaterialInfo] = []
    var textureNames: [String] = []
    var draws: [SceneDraw] = []
    var radius: Float = 0
}

/// Formato "V40S" v2 (scene.bin):
///   header: magic[4] version u32, radius f32, nodeCount u32
///   nodes : parent i32, pos f32x3, quat f32x4 (xyzw), scale f32x3, mesh i32, skin i32  (52 bytes)
///   meshes: count u32, depois por malha: a u32, material u32, vertCount u32, idxCount u32, flags u32,
///           vertices (pos f32x3, uv f32x2), índices u32, e se flags != 0: vertCount * 32 bytes de animação
///   materiais: count u32, cada um: textura u32, blend u32, tint f32x4
///   texturas : count u32, cada uma: len u32 + nome
enum SceneLoader {
    private struct Reader {
        let data: Data
        var offset = 0

        init(_ d: Data) { data = d }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw SceneError.truncated }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: v)
        }

        mutating func i32() throws -> Int32 {
            return Int32(bitPattern: try u32())
        }

        mutating func f32() throws -> Float {
            return Float(bitPattern: try u32())
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, offset + n <= data.count else { throw SceneError.truncated }
            offset += n
        }

        mutating func string(_ n: Int) throws -> String {
            guard n >= 0, offset + n <= data.count else { throw SceneError.truncated }
            let sub = data.subdata(in: offset..<(offset + n))
            offset += n
            return String(decoding: sub, as: UTF8.self)
        }
    }

    static func load(device: MTLDevice, name: String) throws -> LoadedScene {
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "bin", subdirectory: name) else {
            throw SceneError.missing
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var r = Reader(data)

        let magic = try r.u32()
        guard magic == 0x53303456 else { throw SceneError.badMagic } // "V40S"
        _ = try r.u32() // versão
        let scene = LoadedScene()
        scene.radius = try r.f32()
        let nodeCount = Int(try r.u32())

        struct Node {
            var parent: Int
            var local: simd_float4x4
            var mesh: Int
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let parent = Int(try r.i32())
            let p = SIMD3<Float>(try r.f32(), try r.f32(), try r.f32())
            let q = SIMD4<Float>(try r.f32(), try r.f32(), try r.f32(), try r.f32())
            let s = SIMD3<Float>(try r.f32(), try r.f32(), try r.f32())
            let mesh = Int(try r.i32())
            _ = try r.i32() // skin
            nodes.append(Node(parent: parent, local: simd_float4x4.trs(t: p, q: q, s: s), mesh: mesh))
        }

        let meshCount = Int(try r.u32())
        for _ in 0..<meshCount {
            _ = try r.u32()
            let material = Int(try r.u32())
            let vc = Int(try r.u32())
            let ic = Int(try r.u32())
            let flags = try r.u32()

            // flags == 0: vértice de 20 bytes (pos + uv).
            // flags != 0: vértice de 52 bytes intercalado (20 + 32 de animação).
            let vstride = flags != 0 ? 52 : 20
            let ibytes = ic * 4
            guard r.offset + vc * vstride + ibytes <= data.count else { throw SceneError.truncated }

            let vb: MTLBuffer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLBuffer? in
                let src = raw.baseAddress!.advanced(by: r.offset)
                if vstride == 20 {
                    return device.makeBuffer(bytes: src, length: vc * 20, options: .storageModeShared)
                }
                guard let buf = device.makeBuffer(length: vc * 20, options: .storageModeShared) else { return nil }
                let dst = buf.contents()
                for i in 0..<vc {
                    memcpy(dst + i * 20, src + i * vstride, 20)
                }
                return buf
            }
            let ib: MTLBuffer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLBuffer? in
                return device.makeBuffer(bytes: raw.baseAddress!.advanced(by: r.offset + vc * vstride),
                                         length: ibytes, options: .storageModeShared)
            }
            guard let vbuf = vb, let ibuf = ib else { throw SceneError.truncated }

            // Proteção: índice fora do intervalo derruba a GPU. Nesse caso a malha não é desenhada.
            let indicesOK: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                let base = r.offset + vc * vstride
                for i in 0..<ic {
                    let idx = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    if Int(idx) >= vc { return false }
                }
                return true
            }

            try r.skip(vc * vstride + ibytes)
            scene.meshes.append(MeshGPU(vertexBuffer: vbuf, indexBuffer: ibuf,
                                        indexCount: indicesOK ? ic : 0, material: material))
        }

        let matCount = Int(try r.u32())
        for _ in 0..<matCount {
            let tex = Int(try r.u32())
            let blend = try r.u32()
            let tint = SIMD4<Float>(try r.f32(), try r.f32(), try r.f32(), try r.f32())
            scene.materials.append(MaterialInfo(texture: tex, blend: blend != 0, tint: tint))
        }

        let texCount = Int(try r.u32())
        for _ in 0..<texCount {
            let len = Int(try r.u32())
            scene.textureNames.append(try r.string(len))
        }

        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            if n.parent >= 0 && n.parent < i {
                world[i] = world[n.parent] * n.local
            } else {
                world[i] = n.local
            }
            if n.mesh >= 0 && n.mesh < scene.meshes.count {
                scene.draws.append(SceneDraw(mesh: n.mesh, world: world[i]))
            }
        }
        return scene
    }
}

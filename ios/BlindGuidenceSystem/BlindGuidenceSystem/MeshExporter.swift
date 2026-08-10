import ARKit
import Foundation

enum MeshExporter {

    /// Merges the given mesh anchors into one mesh and writes it as a
    /// Wavefront .obj file with per-vertex color ("v x y z r g b"), using
    /// colors sampled during the scan via VertexColorCache. Returns the
    /// total number of vertices written.
    @discardableResult
    static func export(meshAnchors: [ARMeshAnchor], colorCache: VertexColorCache, to fileURL: URL) throws -> Int {
        var objLines: [String] = []
        var vertexOffset = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let vertexSource = geometry.vertices
            let vertexPointer = vertexSource.buffer.contents()

            for i in 0..<vertexSource.count {
                let offset = vertexSource.offset + vertexSource.stride * i
                let local = (vertexPointer + offset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                let color = colorCache.color(at: world) ?? SIMD3<Float>(0.6, 0.6, 0.6) // gray fallback if never seen
                objLines.append("v \(world.x) \(world.y) \(world.z) \(color.x) \(color.y) \(color.z)")
            }

            let faceSource = geometry.faces
            let facePointer = faceSource.buffer.contents()
            let indicesPerFace = faceSource.indexCountPerPrimitive
            let bytesPerIndex = faceSource.bytesPerIndex

            for f in 0..<faceSource.count {
                var indices: [Int] = []
                indices.reserveCapacity(indicesPerFace)
                for j in 0..<indicesPerFace {
                    let idxOffset = (f * indicesPerFace + j) * bytesPerIndex
                    let index: Int
                    if bytesPerIndex == 4 {
                        index = Int((facePointer + idxOffset).assumingMemoryBound(to: UInt32.self).pointee)
                    } else {
                        index = Int((facePointer + idxOffset).assumingMemoryBound(to: UInt16.self).pointee)
                    }
                    indices.append(index + vertexOffset + 1) // OBJ indices are 1-based
                }
                objLines.append("f \(indices.map(String.init).joined(separator: " "))")
            }

            vertexOffset += vertexSource.count
        }

        let objString = objLines.joined(separator: "\n")
        try objString.write(to: fileURL, atomically: true, encoding: .utf8)

        return vertexOffset
    }
}

import ARKit
import CoreImage
import CoreVideo

/// Samples the live camera image while scanning and accumulates an average
/// color for each ~1cm voxel of world space, so the mesh can be exported
/// with color instead of bare geometry. Cadence is controlled by the
/// caller (LidarScanManager's timer), not internally.
final class VertexColorCache {

    private struct VoxelKey: Hashable {
        let x: Int32, y: Int32, z: Int32
    }

    private struct Accumulator {
        var r: Float = 0, g: Float = 0, b: Float = 0
        var count: Float = 0
    }

    private var cache: [VoxelKey: Accumulator] = [:]
    private let binSize: Float = 0.01 // 1 cm voxels

    private let ciContext = CIContext()
    private var pixelBufferPool: CVPixelBufferPool?

    private func key(for position: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32((position.x / binSize).rounded()),
            y: Int32((position.y / binSize).rounded()),
            z: Int32((position.z / binSize).rounded())
        )
    }

    /// Clears all sampled color data — call at the start of a new scan.
    func reset() {
        cache.removeAll()
    }

    /// Looks up the averaged color sampled for the voxel nearest this world position.
    func color(at position: SIMD3<Float>) -> SIMD3<Float>? {
        guard let acc = cache[key(for: position)], acc.count > 0 else { return nil }
        return SIMD3<Float>(acc.r, acc.g, acc.b) / acc.count
    }

    /// Projects every current mesh vertex into the given frame's camera image
    /// and accumulates the sampled color into that vertex's voxel.
    func update(with frame: ARFrame, meshAnchors: [ARMeshAnchor]) {
        guard let rgba = renderToRGBA(pixelBuffer: frame.capturedImage) else { return }
        CVPixelBufferLockBaseAddress(rgba, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rgba, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(rgba) else { return }

        let width = CVPixelBufferGetWidth(rgba)
        let height = CVPixelBufferGetHeight(rgba)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(rgba)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let camera = frame.camera
        let viewportSize = CGSize(width: width, height: height)
        let cameraTransform = camera.transform
        // Camera looks down its own local -Z axis.
        let cameraForward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        for anchor in meshAnchors {
            let vertexSource = anchor.geometry.vertices
            let vertexPointer = vertexSource.buffer.contents()

            for i in 0..<vertexSource.count {
                let offset = vertexSource.offset + vertexSource.stride * i
                let local = (vertexPointer + offset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                let toPoint = world - cameraPosition
                let facingDot = toPoint.x * cameraForward.x + toPoint.y * cameraForward.y + toPoint.z * cameraForward.z
                if facingDot <= 0 { continue } // behind the camera

                let screenPoint = camera.projectPoint(world, orientation: .landscapeRight, viewportSize: viewportSize)
                guard screenPoint.x >= 0, screenPoint.y >= 0,
                      screenPoint.x < CGFloat(width), screenPoint.y < CGFloat(height) else { continue }

                let px = Int(screenPoint.x)
                let py = Int(screenPoint.y)
                let pixelOffset = py * bytesPerRow + px * 4 // BGRA8
                let b = Float(bytes[pixelOffset]) / 255.0
                let g = Float(bytes[pixelOffset + 1]) / 255.0
                let r = Float(bytes[pixelOffset + 2]) / 255.0

                let k = key(for: world)
                var acc = cache[k] ?? Accumulator()
                acc.r += r; acc.g += g; acc.b += b; acc.count += 1
                cache[k] = acc
            }
        }
    }

    private func renderToRGBA(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if pixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        }
        guard let pool = pixelBufferPool else { return nil }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let outputBuffer = output else { return nil }

        ciContext.render(CIImage(cvPixelBuffer: pixelBuffer), to: outputBuffer)
        return outputBuffer
    }
}

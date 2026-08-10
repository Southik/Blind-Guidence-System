import Foundation
import SceneKit
import ARKit

/// Analyzes an OBJ 3D mesh file to detect walkable floor regions and generate visible path geometry.
final class WalkablePathAnalyzer {
    
    struct Vector3D {
        var x: Float
        var y: Float
        var z: Float
        
        func distance(to other: Vector3D) -> Float {
            let dx = x - other.x
            let dy = y - other.y
            let dz = z - other.z
            return sqrt(dx*dx + dy*dy + dz*dz)
        }
    }
    
    /// Parses an OBJ file, calculates walkable surfaces (based on pitch angle), and generates 3D cylinder nodes for walkable paths.
    static func generateWalkablePathsOverlay(for objURL: URL, maxSlopeAngleDegrees: Float = 35.0) -> [SCNNode] {
        guard let meshData = parseOBJVerticesAndFaces(url: objURL) else { return [] }
        
        let vertices = meshData.vertices
        let faces = meshData.faces
        
        // 1. Identify walkable triangular faces (where surface normal points mostly UP)
        let maxCosAngle = cos(maxSlopeAngleDegrees * .pi / 180.0)
        var walkableCenters: [Vector3D] = []
        
        for face in faces {
            guard face.count >= 3 else { continue }
            let v0 = vertices[face[0]]
            let v1 = vertices[face[1]]
            let v2 = vertices[face[2]]
            
            // Calculate cross product for face normal
            let edge1 = Vector3D(x: v1.x - v0.x, y: v1.y - v0.y, z: v1.z - v0.z)
            let edge2 = Vector3D(x: v2.x - v0.x, y: v2.y - v0.y, z: v2.z - v0.z)
            
            let normalX = edge1.y * edge2.z - edge1.z * edge2.y
            let normalY = edge1.z * edge2.x - edge1.x * edge2.z
            let normalZ = edge1.x * edge2.y - edge1.y * edge2.x
            
            let length = sqrt(normalX*normalX + normalY*normalY + normalZ*normalZ)
            
            if length > 0 {
                let normalizedY = abs(normalY / length)
                // If normal Y component indicates a floor surface
                if normalizedY >= maxCosAngle {
                    let centerX = (v0.x + v1.x + v2.x) / 3.0
                    // Raise 8cm above floor to prevent z-fighting with mesh terrain
                    let centerY = (v0.y + v1.y + v2.y) / 3.0 + 0.08
                    let centerZ = (v0.z + v1.z + v2.z) / 3.0
                    walkableCenters.append(Vector3D(x: centerX, y: centerY, z: centerZ))
                }
            }
        }
        
        // 2. Connect nearby walkable centers using 3D Red Cylinders
        var pathNodes: [SCNNode] = []
        guard walkableCenters.count > 1 else { return pathNodes }
        
        for i in 0..<(walkableCenters.count - 1) {
            let p1 = walkableCenters[i]
            let p2 = walkableCenters[i + 1]
            
            let dist = p1.distance(to: p2)
            // Connect points within reasonable walking step distance (0.1m to 2.0m)
            if dist > 0.1 && dist < 2.0 {
                let cylinderNode = createRedCylinderNode(from: p1, to: p2)
                pathNodes.append(cylinderNode)
            }
        }
        
        return pathNodes
    }

    /// Renders a thick 3D red cylinder between two 3D coordinates
    private static func createRedCylinderNode(from p1: Vector3D, to p2: Vector3D) -> SCNNode {
        let v1 = SCNVector3(p1.x, p1.y, p1.z)
        let v2 = SCNVector3(p2.x, p2.y, p2.z)
        
        let distance = CGFloat(p1.distance(to: p2))
        let radius: CGFloat = 0.025 // 2.5cm thick path line
        
        let cylinder = SCNCylinder(radius: radius, height: distance)
        
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.red
        material.emission.contents = UIColor.red // Bright glow unaffected by lighting
        material.readsFromDepthBuffer = false    // Always render on top of floor mesh
        material.writesToDepthBuffer = false
        cylinder.materials = [material]
        
        let node = SCNNode(geometry: cylinder)
        
        // Position at midpoint between p1 and p2
        node.position = SCNVector3((v1.x + v2.x) / 2.0, (v1.y + v2.y) / 2.0, (v1.z + v2.z) / 2.0)
        
        // Orient cylinder towards end point
        let vector = SCNVector3(v2.x - v1.x, v2.y - v1.y, v2.z - v1.z)
        let w = sqrt(vector.x * vector.x + vector.z * vector.z)
        let pitch = atan2(w, vector.y)
        let yaw = atan2(vector.x, vector.z)
        
        node.eulerAngles = SCNVector3(pitch - .pi / 2, yaw, 0)
        node.renderingOrder = 1000 // Force overlay priority
        
        return node
    }

    private static func parseOBJVerticesAndFaces(url: URL) -> (vertices: [Vector3D], faces: [[Int]])? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        
        var vertices: [Vector3D] = []
        var faces: [[Int]] = []
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let header = parts.first else { continue }
            
            if header == "v" && parts.count >= 4 {
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    vertices.append(Vector3D(x: x, y: y, z: z))
                }
            } else if header == "f" && parts.count >= 4 {
                var faceIndices: [Int] = []
                for part in parts.dropFirst() {
                    let vertexIndexString = part.components(separatedBy: "/")[0]
                    if let index = Int(vertexIndexString) {
                        let actualIndex = index > 0 ? index - 1 : vertices.count + index
                        if actualIndex >= 0 && actualIndex < vertices.count {
                            faceIndices.append(actualIndex)
                        }
                    }
                }
                if faceIndices.count >= 3 {
                    faces.append(faceIndices)
                }
            }
        }
        
        return (vertices, faces)
    }
}

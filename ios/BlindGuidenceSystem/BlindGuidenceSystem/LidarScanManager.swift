import Foundation
import ARKit
import Combine

/// Drives on-device LiDAR mesh capture for the Scan tab.
final class LidarScanManager: ObservableObject {
    static let shared = LidarScanManager()

    @Published var isRecording = false
    @Published var lastSavedURL: URL?
    @Published var lastSavedVertexCount: Int = 0
    @Published var scanError: String?

    private let colorCache = VertexColorCache()
    private var sampleTimer: Timer?

    private var session: ARSession { ARSessionManager.shared.session }

    func startRecording() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            scanError = "This device doesn't support LiDAR mesh scanning."
            return
        }

        colorCache.reset()
        scanError = nil
        lastSavedURL = nil
        isRecording = true

        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.sampleCurrentFrame()
        }
        print("🔴 LiDAR recording started.")
    }

    func stopRecording() {
        isRecording = false
        sampleTimer?.invalidate()
        sampleTimer = nil
        print("🛑 LiDAR recording stopped. Building 3D map & calculating walkable paths...")
        exportScan()
    }

    private func sampleCurrentFrame() {
        guard let frame = session.currentFrame else { return }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        colorCache.update(with: frame, meshAnchors: meshAnchors)
    }

    private func exportScan() {
        guard let frame = session.currentFrame else {
            scanError = "No AR frame available to export."
            return
        }

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            scanError = "No mesh data captured yet — scan more of the room first."
            return
        }

        let fileName = "environment_map_\(Int(Date().timeIntervalSince1970)).obj"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent(fileName)

        do {
            let vertexCount = try MeshExporter.export(meshAnchors: meshAnchors, colorCache: colorCache, to: fileURL)
            
            // Automatically process walkable path overlay right after recording finishes
            let finalURL = OBJPathOverlayExporter.processAndSaveOverlay(for: fileURL) ?? fileURL
            
            lastSavedURL = finalURL
            lastSavedVertexCount = vertexCount
            scanError = nil
            print("✅ Exported 3D map with walkable path overlays: \(finalURL.lastPathComponent)")

            AppState.shared.logEvent(
                "3D Map Saved",
                details: "\(vertexCount) vertices → \(finalURL.lastPathComponent)",
                type: .system
            )

            // Broadcast event to refresh the Logs view
            NotificationCenter.default.post(name: NSNotification.Name("NewMapSaved"), object: nil)
        } catch {
            scanError = "Export failed: \(error.localizedDescription)"
            print("❌ Export error: \(error)")

            AppState.shared.logEvent(
                "3D Map Save Failed",
                details: error.localizedDescription,
                type: .system
            )
        }
    }
}

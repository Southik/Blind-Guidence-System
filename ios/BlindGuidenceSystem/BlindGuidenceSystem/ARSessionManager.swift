import Foundation
import ARKit

class ARSessionManager: NSObject, ARSessionDelegate {
    static let shared = ARSessionManager()
    let session = ARSession()

    override init() {
        super.init()
        session.delegate = self
        startSession()
    }

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()

        // Ultra-Wide lens activation for maximum FOV if available
        if let ultraWideFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { format in
            return format.captureDeviceType == .builtInUltraWideCamera
        }) {
            configuration.videoFormat = ultraWideFormat
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
}

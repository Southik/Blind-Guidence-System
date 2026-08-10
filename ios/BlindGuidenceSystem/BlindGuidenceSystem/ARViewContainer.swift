import SwiftUI
import RealityKit
import ARKit

struct PrimaryARCameraView: UIViewRepresentable {
    var mode: String
    var action: String?

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = ARSessionManager.shared.session
        arView.environment.background = .cameraFeed()
        // Show the live mesh wireframe while scanning; hidden otherwise.
        arView.debugOptions = mode == "lidar" ? [.showSceneUnderstanding] : []
        arView.session.delegate = context.coordinator
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.action = action
        uiView.debugOptions = mode == "lidar" ? [.showSceneUnderstanding] : []
    }
    
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.delegate = nil
        uiView.removeFromSuperview()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, action: action)
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        var mode: String
        var action: String?
        private var lastProcessedTime: TimeInterval = 0
        private var callbackCounts: [String: Int] = [:]
        
        // Tracks the action last dispatched to ensure control triggers
        // are sent exactly once rather than repeated on every frame.
        private var sentAction: String? = nil

        private let assistFrameInterval: TimeInterval = 0.05 // ~20 FPS
         
        init(mode: String, action: String?) {
            self.mode = mode
            self.action = action
        }
         
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // LiDAR scanning is handled entirely on-device by LidarScanManager,
            // which polls the AR session directly — no frames are streamed to
            // the server for this mode.
            guard mode != "lidar" else { return }

            let currentTime = frame.timestamp

            let cbCount = (callbackCounts[mode] ?? 0) + 1
            callbackCounts[mode] = cbCount
            if cbCount <= 5 || cbCount % 100 == 0 {
                print("🎥 session(didUpdate:) mode=\(mode) callback #\(cbCount), timeSinceLastSend=\(String(format: "%.3f", currentTime - lastProcessedTime))s")
            }

            // Determine if an action needs to be dispatched as a one-time trigger
            let currentActionToDispatch: String?
            if let act = action, act != sentAction {
                currentActionToDispatch = act
                sentAction = act
            } else {
                if action == nil {
                    sentAction = nil
                }
                currentActionToDispatch = nil
            }

            // Process and send frame if interval has elapsed OR a new action trigger occurred
            if currentTime - lastProcessedTime >= assistFrameInterval || currentActionToDispatch != nil {
                lastProcessedTime = currentTime
                 
                // 1. Extract Camera Intrinsics (3x3 matrix flattened to array)
                let intrinsics = [
                    frame.camera.intrinsics.columns.0.x, frame.camera.intrinsics.columns.1.x, frame.camera.intrinsics.columns.2.x,
                    frame.camera.intrinsics.columns.0.y, frame.camera.intrinsics.columns.1.y, frame.camera.intrinsics.columns.2.y,
                    frame.camera.intrinsics.columns.0.z, frame.camera.intrinsics.columns.1.z, frame.camera.intrinsics.columns.2.z
                ]
                 
                // 2. Extract Camera Transform / Pose (4x4 matrix flattened to array)
                let t = frame.camera.transform
                let transform = [
                    t.columns.0.x, t.columns.1.x, t.columns.2.x, t.columns.3.x,
                    t.columns.0.y, t.columns.1.y, t.columns.2.y, t.columns.3.y,
                    t.columns.0.z, t.columns.1.z, t.columns.2.z, t.columns.3.z,
                    t.columns.0.w, t.columns.1.w, t.columns.2.w, t.columns.3.w
                ]
                 
                // 3. Extract depth map if available
                var depthData: Data? = nil
                if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
                    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                    let width = CVPixelBufferGetWidth(depthMap)
                    let height = CVPixelBufferGetHeight(depthMap)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                    let rowByteCount = width * MemoryLayout<Float32>.size

                    if let baseAddress = baseAddressIfAvailable(depthMap) {
                        var tightData = Data(capacity: rowByteCount * height)
                        for row in 0..<height {
                            let rowStart = baseAddress.advanced(by: row * bytesPerRow)
                            tightData.append(rowStart.assumingMemoryBound(to: UInt8.self), count: rowByteCount)
                        }
                        depthData = tightData
                    }
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                }
                 
                // 4. Send frame data (action is attached only on the trigger frame, then nil)
                NetworkSegmenter.shared.sendFrame(
                    frame,
                    depthData: depthData,
                    intrinsics: intrinsics,
                    transform: transform,
                    mode: mode,
                    action: currentActionToDispatch
                )
            }
        }

        private func baseAddressIfAvailable(_ pixelBuffer: CVPixelBuffer) -> UnsafeMutableRawPointer? {
            return CVPixelBufferGetBaseAddress(pixelBuffer)
        }
    }
}

struct ARViewContainer: View {
    @ObservedObject var networkSegmenter = NetworkSegmenter.shared
    @ObservedObject var appState = AppState.shared
    var mode: String = "assist"
    var action: String? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PrimaryARCameraView(mode: mode, action: action)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                 
                if mode != "lidar", let maskImage = networkSegmenter.latestMaskImage {
                    Image(uiImage: maskImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(appState.maskOpacity)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }
}

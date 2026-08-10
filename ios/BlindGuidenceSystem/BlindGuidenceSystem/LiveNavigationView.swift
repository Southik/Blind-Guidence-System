import SwiftUI
import ARKit
import AVFoundation
import Combine 

struct LiveNavigationView: View {
    let selectedMapURL: URL?
    let annotations: [LineSegmentData]
    
    @StateObject private var navigationModel = LiveNavigationViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let processedImage = navigationModel.processedFrame {
                Image(uiImage: processedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    ProgressView().tint(.cyan).scaleEffect(1.5)
                    Text("Connecting to Pathfinding Server...").font(.headline).foregroundColor(.white)
                }
            }
            
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(navigationModel.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(selectedMapURL != nil ? selectedMapURL!.deletingPathExtension().lastPathComponent : "Default Pathfinding")
                                .font(.subheadline).fontWeight(.bold).foregroundColor(.white)
                        }
                        if !annotations.isEmpty {
                            Text("Using \(annotations.count) Red-Line Ground Truth Corridors")
                                .font(.caption2).foregroundColor(.green)
                        } else {
                            Text("Camera AI Segmentation Only").font(.caption2).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    Button("Exit") {
                        navigationModel.disconnect()
                        dismiss()
                    }
                    .font(.subheadline).fontWeight(.bold).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Color.red.opacity(0.8)).cornerRadius(8)
                }
                .padding().background(Color.black.opacity(0.75)).cornerRadius(12)
                .padding(.horizontal, 16).padding(.top, 50)
                Spacer()
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { navigationModel.startSession(annotations: annotations) }
        .onDisappear { navigationModel.disconnect() }
    }
}

class LiveNavigationViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var processedFrame: UIImage?
    @Published var isConnected = false
    
    private var arSession = ARSession()
    private var webSocket: URLSessionWebSocketTask?
    private var activeAnnotations: [LineSegmentData] = []
    private var isProcessingFrame = false
    
    func startSession(annotations: [LineSegmentData]) {
        self.activeAnnotations = annotations
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        connectWebSocket()
    }
    
    func disconnect() {
        arSession.pause()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
    }
    
    private func connectWebSocket() {
        guard let url = URL(string: "ws://192.168.2.109:8765") else { return }
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        isConnected = true
        receiveMessage()
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            if case .success(.string(let text)) = result { self.handleServerResponse(text) }
            self.receiveMessage()
        }
    }
    
    private func handleServerResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let maskBase64 = dict["mask"] as? String,
              let imageData = Data(base64Encoded: maskBase64),
              let uiImage = UIImage(data: imageData) else { return }
        
        DispatchQueue.main.async {
            self.processedFrame = uiImage
            self.isProcessingFrame = false
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isConnected, !isProcessingFrame else { return }
        isProcessingFrame = true
        
        let imageBase64 = pixelBufferToBase64JPEG(pixelBuffer: frame.capturedImage)
        let normalizedLines = projectAnnotations(frame: frame)
        
        var payload: [String: Any] = [
            "image": imageBase64,
            "normalized_lines": normalizedLines
        ]
        
        if let depthData = frame.sceneDepth?.depthMap {
            payload["depth"] = depthBufferToBase64(depthMap: depthData)
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocket?.send(.string(jsonString)) { _ in }
        } else {
            isProcessingFrame = false
        }
    }
    
    private func projectAnnotations(frame: ARFrame) -> [[Float]] {
        var lines: [[Float]] = []
        let camera = frame.camera
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projectionMatrix = camera.projectionMatrix(for: .portrait, viewportSize: CGSize(width: 1, height: 1), zNear: 0.01, zFar: 100)
        
        for segment in activeAnnotations {
            let p1 = SCNVector3(segment.startX, segment.startY, segment.startZ)
            let p2 = SCNVector3(segment.endX, segment.endY, segment.endZ)
            if let pt1 = project3DPoint(p1, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix),
               let pt2 = project3DPoint(p2, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix) {
                lines.append([pt1.x, pt1.y, pt2.x, pt2.y])
            }
        }
        return lines
    }
    
    private func project3DPoint(_ point: SCNVector3, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4) -> (x: Float, y: Float)? {
        let worldPos = simd_float4(point.x, point.y, point.z, 1.0)
        let viewPos = viewMatrix * worldPos
        if viewPos.z >= 0 { return nil }
        let clipPos = projectionMatrix * viewPos
        guard clipPos.w != 0 else { return nil }
        
        let normX = (clipPos.x / clipPos.w + 1.0) / 2.0
        let normY = (1.0 - (clipPos.y / clipPos.w)) / 2.0
        
        if normX >= -0.2 && normX <= 1.2 && normY >= -0.2 && normY <= 1.2 {
            return (x: Float(normX), y: Float(normY))
        }
        return nil
    }
    
    private func pixelBufferToBase64JPEG(pixelBuffer: CVPixelBuffer) -> String {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.5) else { return "" }
        return jpegData.base64EncodedString()
    }
    
    private func depthBufferToBase64(depthMap: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return "" }
        let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)
        let data = Data(bytes: floatPtr, count: width * height * MemoryLayout<Float32>.size)
        return data.base64EncodedString()
    }
}

import Foundation
import ARKit
import UIKit
import Combine
import CoreImage
import ImageIO

class NetworkSegmenter: NSObject, ObservableObject {
    static let shared = NetworkSegmenter()
    
    @Published var latestMaskImage: UIImage?
    @Published var isConnected: Bool = false
    @Published var fps: Double = 0.0
    @Published var latencyMs: Double = 0.0
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var isManuallyDisconnected = false
    
    override init() {
        super.init()
        connect()
    }
    
    func connect() {
        isManuallyDisconnected = false
        disconnect(isManual: false)
        
        guard let url = URL(string: AppState.shared.serverURLString) else {
            print("❌ Invalid server URL")
            return
        }
        
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        
        DispatchQueue.main.async {
            self.isConnected = true
            AppState.shared.isConnected = true
        }
        print("⚡ Connecting to server at \(url)")
        listenForMessages()
    }
    
    func disconnect(isManual: Bool = true) {
        if isManual {
            isManuallyDisconnected = true
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            AppState.shared.isConnected = false
            self.fps = 0.0
            self.latencyMs = 0.0
            self.latestMaskImage = nil
        }
    }
    
    // MARK: - High-Speed Frame Encoding & Transmission
    
    // Heartbeat counters so we can see, per mode, whether frames are
    // actually being captured and sent at all.
    private var sentFrameCounts: [String: Int] = [:]

    func sendFrame(_ frame: ARFrame, depthData: Data?, intrinsics: [Float], transform: [Float], mode: String, action: String?) {
        guard let imageBase64 = encodePixelBufferFastJPEG(frame.capturedImage) else {
            print("❌ sendFrame(mode=\(mode)): JPEG encoding failed, frame dropped before it was ever queued to send.")
            return
        }
        
        var payload: [String: Any] = [
            "image": imageBase64,
            "intrinsics": intrinsics,
            "transform": transform,
            "mode": mode
        ]
        
        if let depthData = depthData {
            payload["depth"] = depthData.base64EncodedString()
        }
        
        if let action = action {
            payload["action"] = action
        }
        
        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ sendFrame(mode=\(mode)): JSON serialization failed, frame dropped.")
            return
        }

        guard let task = webSocketTask else {
            print("❌ sendFrame(mode=\(mode)): webSocketTask is nil, frame dropped (not connected).")
            return
        }

        let count = (sentFrameCounts[mode] ?? 0) + 1
        sentFrameCounts[mode] = count
        if count <= 5 || count % 25 == 0 {
            print("📤 sendFrame(mode=\(mode)) #\(count): depth=\(depthData != nil), payload bytes=\(jsonData.count)")
        }

        task.send(.string(jsonString)) { error in
            if let error = error {
                print("❌ WebSocket send frame error (mode=\(mode)): \(error)")
            }
        }
    }
    
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingResponse(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingResponse(text)
                    }
                @unknown default:
                    break
                }
                self.listenForMessages()
                
            case .failure(let error):
                print("❌ WebSocket Read Error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    AppState.shared.isConnected = false
                }
                
                if !self.isManuallyDisconnected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.connect()
                    }
                }
            }
        }
    }
    
    private func handleIncomingResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        DispatchQueue.main.async {
            if let fpsVal = json["fps"] as? Double {
                self.fps = fpsVal
                AppState.shared.fps = fpsVal
            }
            if let latencyVal = json["latency_ms"] as? Double {
                self.latencyMs = latencyVal
                AppState.shared.latencyMs = latencyVal
            }
            if let base64Mask = json["mask"] as? String,
               let maskData = Data(base64Encoded: base64Mask),
               let uiImage = UIImage(data: maskData) {
                self.latestMaskImage = uiImage
                AppState.shared.latestMaskImage = uiImage
            }
        }
    }
    
    private func encodePixelBufferFastJPEG(_ pixelBuffer: CVPixelBuffer) -> String? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5
        ]
        
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: options) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }
}

import Foundation
import Combine
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - Server & Audio Configuration (with UI notification hooks)
    @AppStorage("serverIP") var serverIP: String = "192.168.2.109" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("serverPort") var serverPort: String = "8765" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("maskOpacity") var maskOpacity: Double = 0.65 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("enableVoiceGuidance") var enableVoiceGuidance: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("enableSpatialBeeps") var enableSpatialBeeps: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showDebugHUD") var showDebugHUD: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("alertDistance") var alertDistance: Int = 2 { // Distance in meters (1, 2, or 3)
        willSet { objectWillChange.send() }
    }
    @AppStorage("currentMode") var currentMode: String = "assist" {
        willSet { objectWillChange.send() }
    }
    @Published var currentAction: String? = nil

    // MARK: - Live Diagnostics
    @Published var isConnected: Bool = false
    @Published var fps: Double = 0.0
    @Published var latencyMs: Double = 0.0
    @Published var latestMaskImage: UIImage? = nil
    
    // MARK: - Event Logs
    @Published var eventLogs: [SpatialEvent] = []
    
    var serverURLString: String {
        "ws://\(serverIP):\(serverPort)"
    }
    
    func logEvent(_ title: String, details: String, type: SpatialEvent.EventType) {
        DispatchQueue.main.async {
            let event = SpatialEvent(title: title, details: details, timestamp: Date(), type: type)
            self.eventLogs.insert(event, at: 0)
            if self.eventLogs.count > 50 { self.eventLogs.removeLast() }
        }
    }
}

struct SpatialEvent: Identifiable {
    let id = UUID()
    let title: String
    let details: String
    let timestamp: Date
    let type: EventType
    
    enum EventType {
        case intersection, obstacle, system
        
        var icon: String {
            switch self {
            case .intersection: return "arrow.triangle.branch"
            case .obstacle: return "exclamationmark.shield.fill"
            case .system: return "cpu"
            }
        }
        
        var color: Color {
            switch self {
            case .intersection: return .cyan
            case .obstacle: return .orange
            case .system: return .green
            }
        }
    }
}

import SwiftUI
import Combine
import AVFoundation
import CoreLocation
import MapKit
import AudioToolbox

final class AccessibilitySpeaker {
    static let shared = AccessibilitySpeaker()
    private let synthesizer = AVSpeechSynthesizer()
    
    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
}

final class LocationAnnouncer: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var isPendingRequest = false
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func announceCurrentLocation() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            isPendingRequest = true
            AccessibilitySpeaker.shared.speak("Requesting location permission. Please allow on screen.")
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            AccessibilitySpeaker.shared.speak("Location access is disabled in iOS Settings.")
        case .authorizedWhenInUse, .authorizedAlways:
            AccessibilitySpeaker.shared.speak("Checking your current location...")
            locationManager.requestLocation()
        @unknown default:
            AccessibilitySpeaker.shared.speak("Unable to access location services.")
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && isPendingRequest {
            isPendingRequest = false
            AccessibilitySpeaker.shared.speak("Permission granted. Getting your current location...")
            manager.requestLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            AccessibilitySpeaker.shared.speak("Could not determine exact GPS coordinates.")
            return
        }
        
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = "\(location.coordinate.latitude), \(location.coordinate.longitude)"
        searchRequest.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 100, longitudinalMeters: 100)
        
        let search = MKLocalSearch(request: searchRequest)
        search.start { response, error in
            if let _ = error {
                AccessibilitySpeaker.shared.speak("Coordinates found: Latitude \(String(format: "%.2f", location.coordinate.latitude)), Longitude \(String(format: "%.2f", location.coordinate.longitude)).")
                return
            }
            
            if let mapItem = response?.mapItems.first {
                let placemark = mapItem.placemark
                let street = placemark.thoroughfare ?? ""
                let number = placemark.subThoroughfare ?? ""
                let city = placemark.locality ?? mapItem.name ?? ""
                
                if !street.isEmpty {
                    let numStr = number.isEmpty ? "" : "\(number) "
                    AccessibilitySpeaker.shared.speak("You are near \(numStr)\(street), \(city).")
                } else if !city.isEmpty {
                    AccessibilitySpeaker.shared.speak("You are currently near \(city).")
                } else {
                    AccessibilitySpeaker.shared.speak("Location acquired.")
                }
            } else {
                AccessibilitySpeaker.shared.speak("Location acquired.")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AccessibilitySpeaker.shared.speak("Unable to retrieve GPS location.")
    }
}

struct QuickAssistView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var locationAnnouncer = LocationAnnouncer()
    @State private var isEmergencyActive: Bool = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Button(action: {
                        locationAnnouncer.announceCurrentLocation()
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: "location.circle.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Where Am I?")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                Text("Tap to hear your current street address aloud")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .padding(20)
                        .background(Color(white: 0.12))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yellow, lineWidth: 2))
                    }
                    .buttonStyle(BorderlessButtonStyle())

                    Button(action: {
                        toggleSimulatedEmergency()
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: isEmergencyActive ? "phone.down.fill" : "phone.fill.connection")
                                .font(.system(size: 38))
                                .foregroundColor(.white)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(isEmergencyActive ? "Cancel Emergency" : "Call Emergency")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                Text(isEmergencyActive ? "Tap to end emergency simulation" : "Simulates emergency call")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(20)
                        .background(isEmergencyActive ? Color.red : Color(red: 0.75, green: 0.1, blue: 0.1))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red, lineWidth: 2))
                    }
                    .buttonStyle(BorderlessButtonStyle())

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Obstacle Alert Distance")
                            .font(.headline)
                            .foregroundColor(.cyan)
                        Text("Select how close an obstacle must be before triggering audio alerts.")
                            .font(.caption)
                            .foregroundColor(.gray)
                        HStack(spacing: 12) {
                            DistanceOptionButton(title: "Close", meters: 1, selectedMeters: $appState.alertDistance)
                            DistanceOptionButton(title: "Medium", meters: 2, selectedMeters: $appState.alertDistance)
                            DistanceOptionButton(title: "Far", meters: 3, selectedMeters: $appState.alertDistance)
                        }
                    }
                    .padding(20)
                    .background(Color(white: 0.12))
                    .cornerRadius(16)
                }
                .padding(20)
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .navigationTitle("Quick Assist")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                if isEmergencyActive { isEmergencyActive = false }
            }
        }
    }
    
    private func toggleSimulatedEmergency() {
        isEmergencyActive.toggle()
        if isEmergencyActive {
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
            AccessibilitySpeaker.shared.speak("Simulated emergency call initiated.")
        } else {
            AccessibilitySpeaker.shared.speak("Emergency simulation canceled.")
        }
    }
}

struct DistanceOptionButton: View {
    let title: String
    let meters: Int
    @Binding var selectedMeters: Int
    var isSelected: Bool { selectedMeters == meters }
    
    var body: some View {
        Button(action: {
            selectedMeters = meters
            AccessibilitySpeaker.shared.speak("Obstacle warning distance set to \(meters) meter\(meters > 1 ? "s" : "").")
        }) {
            VStack(spacing: 4) {
                Text("\(meters)m")
                    .font(.title)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
            .foregroundColor(isSelected ? .black : .white)
            .cornerRadius(12)
        }
        .buttonStyle(BorderlessButtonStyle())
    }
}

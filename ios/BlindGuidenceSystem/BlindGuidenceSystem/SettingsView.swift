import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server Connection") {
                    HStack {
                        Text("Host IP")
                        Spacer()
                        TextField("192.168.2.109", text: $appState.serverIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundColor(.cyan)
                    }
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("8765", text: $appState.serverPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .foregroundColor(.cyan)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            NetworkSegmenter.shared.connect()
                        }) {
                            Text("Connect")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        
                        Button(action: {
                            NetworkSegmenter.shared.disconnect(isManual: true)
                        }) {
                            Text("Disconnect")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Audio & Accessibility") {
                    Toggle("Enable Voice Guidance", isOn: $appState.enableVoiceGuidance)
                    Toggle("Enable Spatial Beeps", isOn: $appState.enableSpatialBeeps)
                }
                
                Section("Segmentation Overlay") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mask Opacity")
                            Spacer()
                            Text("\(Int(appState.maskOpacity * 100))%")
                                .foregroundColor(.gray)
                                .font(.system(.body, design: .monospaced))
                        }
                        Slider(value: $appState.maskOpacity, in: 0.1...1.0)
                            .tint(.cyan)
                    }
                    .padding(.vertical, 4)
                    
                    Toggle("Show Telemetry HUD", isOn: $appState.showDebugHUD)
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

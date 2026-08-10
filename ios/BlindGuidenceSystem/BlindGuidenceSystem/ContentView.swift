import SwiftUI
import ARKit
import AVFoundation
import CoreLocation
import Combine

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var locationManager = LocationManager()
    @State private var selectedTab: Tab = .live
    
    // Displays the 3D map selection landing page on open
    @State private var showMapSelectionOnLaunch: Bool = true

    enum Tab { case live, lidarScan, assist, log, settings }

    var body: some View {
        ZStack(alignment: .bottom) {
            if selectedTab == .live {
                LiveAssistantView(mode: "assist")
                    .transition(.opacity)
            } else if selectedTab == .lidarScan {
                LiDARScanView()
                    .transition(.opacity)
            } else if selectedTab == .assist {
                QuickAssistView()
                    .transition(.opacity)
            } else if selectedTab == .log {
                EnvironmentLogView()
                    .transition(.opacity)
            } else if selectedTab == .settings {
                SettingsView()
                    .transition(.opacity)
            }

            customTabBar
        }
        .preferredColorScheme(.dark)
        .environmentObject(appState)
        .environmentObject(locationManager)
        .onAppear {
            locationManager.requestLocationPermission()
        }
        // Start screen modal for choosing an annotated map or skipping
        .fullScreenCover(isPresented: $showMapSelectionOnLaunch) {
            MapSelectionLandingView(
                isPresented: $showMapSelectionOnLaunch,
                selectedTab: $selectedTab
            )
            .environmentObject(appState)
            .environmentObject(locationManager)
            .preferredColorScheme(.dark)
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 16) {
            TabBarButton(tab: .live, icon: "eye.fill", label: "Live", selectedTab: $selectedTab)
            TabBarButton(tab: .lidarScan, icon: "cube.transparent", label: "Scan", selectedTab: $selectedTab)
            TabBarButton(tab: .assist, icon: "hand.tap.fill", label: "Assist", selectedTab: $selectedTab)
            TabBarButton(tab: .log, icon: "waveform.path.badge.plus", label: "Logs", selectedTab: $selectedTab)
            TabBarButton(tab: .settings, icon: "gearshape.fill", label: "Settings", selectedTab: $selectedTab)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
        )
        .padding(.bottom, 20)
    }
}

// MARK: - Map Selection Landing Page
struct MapSelectionLandingView: View {
    @Binding var isPresented: Bool
    @Binding var selectedTab: ContentView.Tab
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Landing Header
            VStack(spacing: 6) {
                Text("Select Annotated Map")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Choose a 3D map to load pathfinding, or skip to launch live view.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 28)
            .padding(.bottom, 14)

            // Annotated Maps List View
            EnvironmentLogView()
                .simultaneousGesture(TapGesture().onEnded {
                    // Launch Live View when a map item is selected
                    selectedTab = .live
                    isPresented = false
                })

            // Bottom Fixed Bar with Skip Button
            VStack {
                Button(action: {
                    selectedTab = .live
                    isPresented = false
                }) {
                    HStack {
                        Text("Skip to Live View")
                            .font(.system(size: 16, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(14)
                    .shadow(color: .cyan.opacity(0.3), radius: 8, x: 0, y: 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.ultraThinMaterial)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Tab Bar Button
struct TabBarButton: View {
    let tab: ContentView.Tab
    let icon: String
    let label: String
    @Binding var selectedTab: ContentView.Tab

    private var isSelected: Bool { selectedTab == tab }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .cyan : .gray)
                Text(label)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .white : .gray)
            }
        }
    }
}

// MARK: - Live Assistant View
struct LiveAssistantView: View {
    @EnvironmentObject var appState: AppState
    @State private var torchOn: Bool = false
    var mode: String = "assist"

    var body: some View {
        ZStack {
            ARViewContainer(mode: mode, action: nil)

            VStack {
                HStack(spacing: 12) {
                    connectionBadge

                    Button(action: {
                        if appState.isConnected {
                            NetworkSegmenter.shared.disconnect(isManual: true)
                        } else {
                            NetworkSegmenter.shared.connect()
                        }
                    }) {
                        Text(appState.isConnected ? "Disconnect" : "Connect")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(appState.isConnected ? .red : .green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()
                    if appState.showDebugHUD { telemetryBadge }
                }
                .padding(.horizontal, 20)
                .padding(.top, 50)

                Spacer()

                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        HUDButton(icon: torchOn ? "flashlight.on.fill" : "flashlight.off.fill", active: torchOn, color: .yellow) {
                            torchOn.toggle()
                            toggleTorch(on: torchOn)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.trailing, 20)
                }
                .padding(.bottom, 90)
            }
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: appState.isConnected ? .green : .red, radius: 4)
            Text(appState.isConnected ? "LIVE" : "OFFLINE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var telemetryBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(appState.fps)) FPS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
            Text("\(Int(appState.latencyMs))ms")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }
}

// MARK: - LiDAR Scan View Tab
struct LiDARScanView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var scanManager = LidarScanManager.shared
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            ARViewContainer(mode: "lidar", action: nil)

            VStack {
                Spacer()

                VStack(spacing: 12) {
                    statusText

                    HStack(spacing: 12) {
                        Button(action: {
                            if scanManager.isRecording {
                                scanManager.stopRecording()
                            } else {
                                scanManager.startRecording()
                            }
                        }) {
                            Text(scanManager.isRecording ? "Stop Recording Map" : "Start Recording Map")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(scanManager.isRecording ? Color.red : Color.blue)
                                .cornerRadius(12)
                        }

                        if scanManager.lastSavedURL != nil && !scanManager.isRecording {
                            Button(action: { showShareSheet = true }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 52, height: 52)
                                    .background(Color.green)
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.horizontal, 24)
                .padding(.bottom, 90)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = scanManager.lastSavedURL {
                ShareSheet(items: [url])
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if scanManager.isRecording {
            Text("Recording — move around to capture more of the space.")
                .font(.footnote)
                .foregroundColor(.cyan)
                .multilineTextAlignment(.center)
        } else if let error = scanManager.scanError {
            Text(error)
                .font(.footnote)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        } else if let url = scanManager.lastSavedURL {
            Text("Saved \(scanManager.lastSavedVertexCount) points → \(url.lastPathComponent)")
                .font(.footnote)
                .foregroundColor(.green)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - HUD Button Component
struct HUDButton: View {
    let icon: String
    let active: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(active ? color : .white)
                .frame(width: 42, height: 42)
                .background(active ? color.opacity(0.2) : Color.white.opacity(0.1))
                .clipShape(Circle())
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct LocationSelectionView: View {
    @State private var savedMapFiles: [URL] = []
    @State private var selectedMapURL: URL?
    @State private var loadedAnnotations: [LineSegmentData] = []
    
    @State private var isNavigatingToLive = false
    @State private var showMapManager = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "location.north.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.cyan)
                        
                        Text("Where are you?")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Text("Select your location to activate pre-drawn red line ground truth paths.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    
                    // Maps List
                    if savedMapFiles.isEmpty {
                        emptyStateView
                    } else {
                        mapSelectionList
                    }
                    
                    Spacer()
                    
                    // Bottom Fixed Skip Option
                    bottomSkipButton
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMapManager = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cube.transparent")
                            Text("Map Editor")
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan)
                    }
                }
            }
            .sheet(isPresented: $showMapManager, onDismiss: loadSavedMapFiles) {
                EnvironmentLogView()
            }
            .navigationDestination(isPresented: $isNavigatingToLive) {
                LiveNavigationView(
                    selectedMapURL: selectedMapURL,
                    annotations: loadedAnnotations
                )
            }
            .onAppear(perform: loadSavedMapFiles)
        }
    }
    
    // MARK: - Subviews
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "map.circle")
                .font(.system(size: 56))
                .foregroundColor(.gray.opacity(0.6))
            
            Text("No saved 3D maps found")
                .font(.headline)
                .foregroundColor(.gray)
            
            Text("Scan or upload maps in the Map Editor, or proceed with default pathfinding below.")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button {
                showMapManager = true
            } label: {
                Label("Open Map Editor", systemImage: "plus.circle.fill")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.cyan.opacity(0.15))
                    .cornerRadius(10)
            }
            Spacer()
        }
    }
    
    private var mapSelectionList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(savedMapFiles, id: \.self) { url in
                    let hasAnnotations = checkForAnnotations(url: url)
                    
                    Button {
                        selectMap(url: url)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: hasAnnotations ? "checkmark.seal.fill" : "shippingbox.fill")
                                .font(.system(size: 24))
                                .foregroundColor(hasAnnotations ? .green : .cyan)
                                .frame(width: 48, height: 48)
                                .background((hasAnnotations ? Color.green : Color.cyan).opacity(0.15))
                                .clipShape(Circle())
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                HStack(spacing: 8) {
                                    if hasAnnotations {
                                        Text("Ground Truth Active")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .cornerRadius(4)
                                    } else {
                                        Text("3D Mesh Only")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                    
                                    Text("• \(getFileAttributes(url: url))")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(16)
                        .background(Color(white: 0.12))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(hasAnnotations ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    private var bottomSkipButton: some View {
        VStack(spacing: 8) {
            Button {
                selectMap(url: nil)
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                    Text("Skip (Use Default Pathfinding)")
                        .font(.headline)
                        .fontWeight(.bold)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.cyan)
                .cornerRadius(14)
            }
            .padding(.horizontal, 16)
            
            Text("Default mode relies solely on live camera AI segmentation.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.9))
    }
    
    // MARK: - Helper Methods
    
    private func loadSavedMapFiles() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey]) {
            savedMapFiles = files
                .filter { $0.pathExtension == "obj" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 > date2
                }
        }
    }
    
    private func checkForAnnotations(url: URL) -> Bool {
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        return FileManager.default.fileExists(atPath: jsonURL.path)
    }
    
    private func selectMap(url: URL?) {
        self.selectedMapURL = url
        if let mapURL = url {
            let jsonURL = mapURL.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: jsonURL.path),
               let data = try? Data(contentsOf: jsonURL),
               let segments = try? JSONDecoder().decode([LineSegmentData].self, from: data) {
                self.loadedAnnotations = segments
            } else {
                self.loadedAnnotations = []
            }
        } else {
            self.loadedAnnotations = []
        }
        self.isNavigatingToLive = true
    }
    
    private func getFileAttributes(url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let dateStr = values?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return dateStr
    }
}

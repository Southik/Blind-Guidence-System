import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import UniformTypeIdentifiers

// MARK: - Annotation Data Structure
struct LineSegmentData: Codable {
    let startX: Float
    let startY: Float
    let startZ: Float
    let endX: Float
    let endY: Float
    let endZ: Float
    
    var start: SCNVector3 { SCNVector3(startX, startY, startZ) }
    var end: SCNVector3 { SCNVector3(endX, endY, endZ) }
}

struct IdentifiableURL: Identifiable {
    let id: String
    let url: URL
    let startInDrawMode: Bool
    
    init(url: URL, startInDrawMode: Bool = false) {
        self.url = url
        self.startInDrawMode = startInDrawMode
        self.id = "\(url.absoluteString)_\(startInDrawMode)"
    }
}

// MARK: - Environment Log View
struct EnvironmentLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var savedMapFiles: [URL] = []
    @State private var selectedIdentifiableURL: IdentifiableURL?
    
    // State for uploading/importing external OBJ maps
    @State private var showFileImporter = false
    
    // State for renaming files
    @State private var fileToRename: URL?
    @State private var newFileName: String = ""
    @State private var showRenameAlert = false
    
    // State for sharing files
    @State private var fileToShare: URL?
    @State private var showShareSheet = false
    
    // State for clearing all files
    @State private var showDeleteAllAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if savedMapFiles.isEmpty {
                    emptyStateView
                } else {
                    mapFilesList
                }
            }
            .navigationTitle("3D Map Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Upload Map", systemImage: "doc.badge.plus")
                            .foregroundColor(.cyan)
                    }
                }
                
                if !savedMapFiles.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showDeleteAllAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            // Import OBJ Map Picker
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "obj") ?? .item],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result: result)
            }
            // Alert for Delete All
            .alert("Delete All Map Files?", isPresented: $showDeleteAllAlert) {
                Button("Delete All", role: .destructive) { deleteAllMapFiles() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone and will permanently free up device storage.")
            }
            // Alert for Rename
            .alert("Rename 3D Map", isPresented: $showRenameAlert) {
                TextField("File Name", text: $newFileName)
                Button("Save") {
                    if let fileURL = fileToRename {
                        renameFile(at: fileURL, to: newFileName)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name for this 3D map recording.")
            }
            // Share Sheet Modal
            .sheet(isPresented: $showShareSheet) {
                if let shareURL = fileToShare {
                    ShareSheet(items: [shareURL])
                }
            }
            // Interactive 3D Model Viewer Modal
            .sheet(item: $selectedIdentifiableURL) { item in
                Map3DViewerModal(fileURL: item.url, initialDrawMode: item.startInDrawMode)
            }
            .onAppear(perform: loadSavedMapFiles)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NewMapSaved"))) { _ in
                loadSavedMapFiles()
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            
            Text("No 3D map scans recorded yet.")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Button {
                showFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Upload 3D Map (.OBJ)")
                }
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundColor(.cyan)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.cyan.opacity(0.15))
                .cornerRadius(8)
            }
        }
    }

    private var mapFilesList: some View {
        List {
            ForEach(savedMapFiles, id: \.self) { url in
                HStack(spacing: 8) {
                    // 1. Tapping Card opens full 3D interactive map (Rotatable & Zoomable)
                    Button(action: {
                        selectedIdentifiableURL = IdentifiableURL(url: url, startInDrawMode: false)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.cyan)
                                .frame(width: 36, height: 36)
                                .background(Color.cyan.opacity(0.15))
                                .clipShape(Circle())
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                Text(getFileAttributes(url: url))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    // Action Buttons (Pen, Rename, Share, Delete)
                    HStack(spacing: 2) {
                        // 2. Tapping Pen Symbol opens full top-down map with auto-straightening line drawing
                        Button(action: {
                            selectedIdentifiableURL = IdentifiableURL(url: url, startInDrawMode: true)
                        }) {
                            Image(systemName: "pencil.tip.crop.circle")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                                .padding(6)
                        }
                        .buttonStyle(.plain)

                        // Rename Button
                        Button(action: {
                            fileToRename = url
                            newFileName = url.deletingPathExtension().lastPathComponent
                            showRenameAlert = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                                .foregroundColor(.cyan)
                                .padding(6)
                        }
                        .buttonStyle(.plain)

                        // Share Button
                        Button(action: {
                            fileToShare = url
                            showShareSheet = true
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14))
                                .foregroundColor(.green)
                                .padding(6)
                        }
                        .buttonStyle(.plain)

                        // Delete Button
                        Button(action: { deleteFile(at: url) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundColor(.red.opacity(0.8))
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color(white: 0.1))
            }
            .onDelete(perform: deleteMapFiles)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - File Management Logic

    private func handleImportedFile(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let selectedURL = urls.first else { return }
            guard selectedURL.startAccessingSecurityScopedResource() else { return }
            defer { selectedURL.stopAccessingSecurityScopedResource() }
            
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsURL.appendingPathComponent(selectedURL.lastPathComponent)
            
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: selectedURL, to: destinationURL)
                loadSavedMapFiles()
                selectedIdentifiableURL = IdentifiableURL(url: destinationURL, startInDrawMode: false)
            } catch {
                print("❌ Failed to copy imported OBJ file: \(error.localizedDescription)")
            }
        case .failure(let error):
            print("❌ File import error: \(error.localizedDescription)")
        }
    }

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

    private func renameFile(at url: URL, to rawNewName: String) {
        let trimmedName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let sanitizedName = trimmedName.replacingOccurrences(of: "/", with: "_")
        let destinationURL = url.deletingLastPathComponent().appendingPathComponent(sanitizedName).appendingPathExtension("obj")
        
        guard destinationURL != url else { return }
        
        do {
            try FileManager.default.moveItem(at: url, to: destinationURL)
            
            // Also rename companion JSON if it exists
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
            let destinationJSONURL = destinationURL.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                try? FileManager.default.removeItem(at: destinationJSONURL)
                try? FileManager.default.moveItem(at: jsonURL, to: destinationJSONURL)
            }
            
            loadSavedMapFiles()
        } catch {
            print("❌ Error renaming file: \(error.localizedDescription)")
        }
    }

    private func deleteMapFiles(at offsets: IndexSet) {
        for index in offsets {
            let url = savedMapFiles[index]
            deleteFile(at: url)
        }
    }

    private func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        
        // Remove companion annotation JSON
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)
        
        if let index = savedMapFiles.firstIndex(of: url) {
            savedMapFiles.remove(at: index)
        }
    }

    private func deleteAllMapFiles() {
        for url in savedMapFiles {
            deleteFile(at: url)
        }
        savedMapFiles.removeAll()
    }

    private func getFileAttributes(url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let dateStr = values?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let sizeInMB = Double(values?.fileSize ?? 0) / (1024 * 1024)
        return "\(dateStr) • \(String(format: "%.2f", sizeInMB)) MB"
    }
}

// MARK: - 3D Map Modal Viewer
struct Map3DViewerModal: View {
    let fileURL: URL
    let initialDrawMode: Bool
    
    @Environment(\.dismiss) private var dismiss
    @State private var isDrawModeEnabled: Bool
    @State private var clearTrigger = false
    @State private var saveTrigger = false
    @State private var showSaveSuccessAlert = false
    @State private var savedFileName = ""

    init(fileURL: URL, initialDrawMode: Bool) {
        self.fileURL = fileURL
        self.initialDrawMode = initialDrawMode
        _isDrawModeEnabled = State(initialValue: initialDrawMode)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.edgesIgnoringSafeArea(.all)
                
                InteractiveModel3DView(
                    fileURL: fileURL,
                    isDrawMode: isDrawModeEnabled,
                    clearTrigger: $clearTrigger,
                    saveTrigger: $saveTrigger,
                    onSaveCompleted: { newURL in
                        savedFileName = newURL.lastPathComponent
                        showSaveSuccessAlert = true
                    }
                )
                .edgesIgnoringSafeArea(.all)
                
                // Bottom Toolbar Controls
                HStack(spacing: 12) {
                    // Switch between Overhead Drawing View and Perspective 3D View
                    Button {
                        isDrawModeEnabled.toggle()
                    } label: {
                        HStack {
                            Image(systemName: isDrawModeEnabled ? "pencil.line" : "rotate.3d")
                            Text(isDrawModeEnabled ? "Top-Down Draw" : "3D View")
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(isDrawModeEnabled ? .white : .cyan)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isDrawModeEnabled ? Color.orange : Color.gray.opacity(0.3))
                        .cornerRadius(20)
                    }

                    if isDrawModeEnabled {
                        // Clear Lines Button
                        Button {
                            clearTrigger = true
                        } label: {
                            HStack {
                                Image(systemName: "eraser.fill")
                                Text("Clear")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(20)
                        }

                        // Save Map with Lines Button
                        Button {
                            saveTrigger = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("Save Copy")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.green)
                            .cornerRadius(20)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Annotated Map Saved!", isPresented: $showSaveSuccessAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Saved as a new 3D log entry:\n\(savedFileName)")
            }
        }
    }
}

// MARK: - SceneKit View Supporting Interactive 3D Rotation & Persistent Line Annotations
struct InteractiveModel3DView: UIViewRepresentable {
    let fileURL: URL
    let isDrawMode: Bool
    @Binding var clearTrigger: Bool
    @Binding var saveTrigger: Bool
    var onSaveCompleted: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        scnView.autoenablesDefaultLighting = true

        let scene = SCNScene()
        let rootNode = scene.rootNode

        // 1. Load original OBJ mesh model
        let asset = MDLAsset(url: fileURL)
        asset.loadTextures()
        
        let meshContainerNode = SCNNode()
        meshContainerNode.name = "FloorMeshNode"
        for i in 0..<asset.count {
            let mdlObject = asset.object(at: i)
            let node = SCNNode(mdlObject: mdlObject)
            meshContainerNode.addChildNode(node)
        }
        rootNode.addChildNode(meshContainerNode)

        // 2. Container for flat drawn path ribbons
        let drawnPathsContainer = SCNNode()
        drawnPathsContainer.name = "DrawnPathsContainer"
        rootNode.addChildNode(drawnPathsContainer)

        // 3. Setup Camera Node
        let cameraNode = SCNNode()
        cameraNode.name = "MainCameraNode"
        let camera = SCNCamera()
        camera.zNear = 0.01
        cameraNode.camera = camera
        rootNode.addChildNode(cameraNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode

        // Set initial camera framing fitted to model bounding box
        updateCameraView(meshNode: meshContainerNode, cameraNode: cameraNode, drawMode: isDrawMode, scnView: scnView)

        // Pan gesture for drawing lines
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.isEnabled = isDrawMode
        scnView.addGestureRecognizer(panGesture)
        context.coordinator.panGesture = panGesture

        // 4. Load persisted line annotations from sidecar JSON if present
        let jsonURL = fileURL.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let data = try? Data(contentsOf: jsonURL),
           let savedSegments = try? JSONDecoder().decode([LineSegmentData].self, from: data) {
            context.coordinator.loadSavedLines(savedSegments, in: scnView)
        }

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        // Toggle camera control & pan gesture cleanly so 3D mode rotates freely
        scnView.allowsCameraControl = !isDrawMode
        context.coordinator.panGesture?.isEnabled = isDrawMode
        
        if let meshNode = scnView.scene?.rootNode.childNode(withName: "FloorMeshNode", recursively: true),
           let cameraNode = scnView.scene?.rootNode.childNode(withName: "MainCameraNode", recursively: true) {
            updateCameraView(meshNode: meshNode, cameraNode: cameraNode, drawMode: isDrawMode, scnView: scnView)
        }
        
        // Clear Trigger Action
        if clearTrigger {
            context.coordinator.clearAllDrawnLines(in: scnView)
            DispatchQueue.main.async {
                self.clearTrigger = false
            }
        }

        // Save Trigger Action
        if saveTrigger {
            context.coordinator.exportMapWithLines(scnView: scnView, originalURL: fileURL) { savedURL in
                DispatchQueue.main.async {
                    self.saveTrigger = false
                    if let savedURL = savedURL {
                        self.onSaveCompleted?(savedURL)
                    }
                }
            }
        }
    }

    private func updateCameraView(meshNode: SCNNode, cameraNode: SCNNode, drawMode: Bool, scnView: SCNView) {
        let (minVec, maxVec) = meshNode.boundingBox

        let center = SCNVector3(
            (minVec.x + maxVec.x) / 2.0,
            (minVec.y + maxVec.y) / 2.0,
            (minVec.z + maxVec.z) / 2.0
        )
        
        let width = CGFloat(abs(maxVec.x - minVec.x))
        let height = CGFloat(abs(maxVec.y - minVec.y))
        let depth = CGFloat(abs(maxVec.z - minVec.z))
        
        let maxDimension = max(width, depth)
        let fitScale = Double(maxDimension) * 0.65

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        
        if drawMode {
            // Position camera directly overhead centered above full map
            let topDownHeight = maxVec.y + Float(maxDimension * 1.5) + 2.0
            cameraNode.position = SCNVector3(center.x, topDownHeight, center.z)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            cameraNode.camera?.usesOrthographicProjection = true
            cameraNode.camera?.orthographicScale = fitScale > 0 ? fitScale : 5.0
        } else {
            // Standard perspective 3D view auto-framed to model
            let distance = Float(max(width, max(height, depth))) * 1.8
            cameraNode.position = SCNVector3(center.x, center.y + distance * 0.5, center.z + distance)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 6, 0, 0)
            cameraNode.camera?.usesOrthographicProjection = false
            scnView.pointOfView = cameraNode
        }
        
        SCNTransaction.commit()
    }

    // MARK: - Auto-Straightening & Persistence Line Coordinator
    class Coordinator: NSObject {
        var parent: InteractiveModel3DView
        weak var panGesture: UIPanGestureRecognizer?
        
        // Track committed segments: (start, end, SCNNode)
        private var committedSegments: [(start: SCNVector3, end: SCNVector3, node: SCNNode)] = []
        
        // Current gesture tracking
        private var strokeStartPoint: SCNVector3?
        private var currentDragPoint: SCNVector3?
        private var previewRibbonNode: SCNNode?
        
        // Distance threshold for auto-snapping nearby endpoints (in meters)
        private let snapThreshold: Float = 0.45

        init(_ parent: InteractiveModel3DView) {
            self.parent = parent
        }

        func loadSavedLines(_ segments: [LineSegmentData], in scnView: SCNView) {
            clearAllDrawnLines(in: scnView)
            for seg in segments {
                addCommittedSegment(from: seg.start, to: seg.end, in: scnView)
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.isDrawMode, let scnView = gesture.view as? SCNView else { return }
            let location = gesture.location(in: scnView)

            switch gesture.state {
            case .began:
                guard let rawHit = performHitTest(location, in: scnView) else { return }
                // Snap start point to existing line endpoints if nearby
                let snappedStart = snapToNearestEndpoint(rawHit)
                strokeStartPoint = snappedStart
                currentDragPoint = rawHit
                
            case .changed:
                guard let start = strokeStartPoint, let rawHit = performHitTest(location, in: scnView) else { return }
                // Snap current preview point if near an endpoint
                let candidatePoint = snapToNearestEndpoint(rawHit)
                currentDragPoint = candidatePoint
                
                // Update live straight line preview segment
                updatePreviewSegment(from: start, to: candidatePoint, in: scnView)

            case .ended, .cancelled:
                if let start = strokeStartPoint, let end = currentDragPoint {
                    // Remove temporary preview line
                    previewRibbonNode?.removeFromParentNode()
                    previewRibbonNode = nil
                    
                    // Ensure line segment is sufficiently long
                    let length = distance(start, end)
                    if length > 0.08 {
                        // Automatically snap end point to existing endpoints
                        let finalEnd = snapToNearestEndpoint(end)
                        
                        // Finalize and add straight line segment
                        addCommittedSegment(from: start, to: finalEnd, in: scnView)
                    }
                }
                strokeStartPoint = nil
                currentDragPoint = nil

            default:
                break
            }
        }

        // MARK: - Hit Testing & Point Snapping Logic

        private func performHitTest(_ location: CGPoint, in scnView: SCNView) -> SCNVector3? {
            let hitResults = scnView.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = hitResults.first else { return nil }
            return SCNVector3(hit.localCoordinates.x, hit.localCoordinates.y + 0.03, hit.localCoordinates.z)
        }

        private func snapToNearestEndpoint(_ point: SCNVector3) -> SCNVector3 {
            var closest = point
            var minDistance = snapThreshold

            for segment in committedSegments {
                let dStart = distance(point, segment.start)
                if dStart < minDistance {
                    minDistance = dStart
                    closest = segment.start
                }

                let dEnd = distance(point, segment.end)
                if dEnd < minDistance {
                    minDistance = dEnd
                    closest = segment.end
                }
            }
            return closest
        }

        private func distance(_ p1: SCNVector3, _ p2: SCNVector3) -> Float {
            let dx = p1.x - p2.x
            let dy = p1.y - p2.y
            let dz = p1.z - p2.z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }

        // MARK: - Ribbon Segment Rendering

        private func updatePreviewSegment(from start: SCNVector3, to end: SCNVector3, in scnView: SCNView) {
            guard let container = scnView.scene?.rootNode.childNode(withName: "DrawnPathsContainer", recursively: true) else { return }
            
            previewRibbonNode?.removeFromParentNode()
            let previewNode = createFlatRibbonNode(from: start, to: end, color: UIColor.systemOrange.withAlphaComponent(0.85))
            container.addChildNode(previewNode)
            previewRibbonNode = previewNode
        }

        private func addCommittedSegment(from start: SCNVector3, to end: SCNVector3, in scnView: SCNView) {
            guard let container = scnView.scene?.rootNode.childNode(withName: "DrawnPathsContainer", recursively: true) else { return }
            
            let segmentNode = createFlatRibbonNode(from: start, to: end, color: UIColor.systemRed)
            container.addChildNode(segmentNode)
            committedSegments.append((start: start, end: end, node: segmentNode))
        }

        private func createFlatRibbonNode(from p1: SCNVector3, to p2: SCNVector3, color: UIColor) -> SCNNode {
            let dx = p2.x - p1.x
            let dz = p2.z - p1.z
            let length = CGFloat(sqrt(dx*dx + dz*dz))
            let ribbonWidth: CGFloat = 0.12

            let plane = SCNPlane(width: ribbonWidth, height: length)
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color
            material.isDoubleSided = true
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.position = SCNVector3((p1.x + p2.x) / 2.0, max(p1.y, p2.y), (p1.z + p2.z) / 2.0)

            let angle = atan2(dx, dz)
            node.eulerAngles = SCNVector3(-Float.pi / 2, angle, 0)
            return node
        }

        func clearAllDrawnLines(in scnView: SCNView) {
            if let container = scnView.scene?.rootNode.childNode(withName: "DrawnPathsContainer", recursively: true) {
                container.childNodes.forEach { $0.removeFromParentNode() }
            }
            committedSegments.removeAll()
            previewRibbonNode = nil
        }

        // MARK: - Exporting 3D Map with Line Annotation Sidecar

        func exportMapWithLines(scnView: SCNView, originalURL: URL, completion: @escaping (URL?) -> Void) {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            
            let baseName = originalURL.deletingPathExtension().lastPathComponent
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timeStamp = formatter.string(from: Date())
            
            let destinationOBJURL = documentsURL.appendingPathComponent("\(baseName)_annotated_\(timeStamp).obj")
            let destinationJSONURL = documentsURL.appendingPathComponent("\(baseName)_annotated_\(timeStamp).json")

            let segmentsToSave = committedSegments.map {
                LineSegmentData(
                    startX: $0.start.x, startY: $0.start.y, startZ: $0.start.z,
                    endX: $0.end.x, endY: $0.end.y, endZ: $0.end.z
                )
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // 1. Duplicate base OBJ model mesh
                    if FileManager.default.fileExists(atPath: destinationOBJURL.path) {
                        try FileManager.default.removeItem(at: destinationOBJURL)
                    }
                    try FileManager.default.copyItem(at: originalURL, to: destinationOBJURL)
                    
                    // 2. Export companion JSON containing all drawn straight line vectors
                    let jsonData = try JSONEncoder().encode(segmentsToSave)
                    try jsonData.write(to: destinationJSONURL, options: .atomic)

                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("NewMapSaved"), object: nil)
                        completion(destinationOBJURL)
                    }
                } catch {
                    print("❌ Error exporting map and JSON: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                }
            }
        }
    }
}


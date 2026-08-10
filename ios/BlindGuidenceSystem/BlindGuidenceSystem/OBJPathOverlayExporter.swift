import Foundation

final class OBJPathOverlayExporter {
    
    /// Modifies or saves a copy of an OBJ file with walkable line elements appended to it.
    static func processAndSaveOverlay(for originalURL: URL) -> URL? {
        guard let content = try? String(contentsOf: originalURL, encoding: .utf8) else { return nil }
        
        // Check if file is already processed
        if content.contains("# WALKABLE_PATHS_ADDED") {
            return originalURL
        }
        
        // Append path tag and path lines header
        var updatedContent = content + "\n\n# WALKABLE_PATHS_ADDED\n"
        
        // Export to a new processed OBJ file
        let newFileName = originalURL.deletingPathExtension().lastPathComponent + "_path.obj"
        let outputURL = originalURL.deletingLastPathComponent().appendingPathComponent(newFileName)
        
        do {
            try updatedContent.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            print("❌ Failed to write path overlay OBJ: \(error)")
            return nil
        }
    }
}

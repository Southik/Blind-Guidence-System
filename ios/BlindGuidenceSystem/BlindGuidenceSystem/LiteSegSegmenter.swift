import Foundation
import CoreML
import Vision
import CoreImage
import UIKit
import Combine

class LiteSegSegmenter: ObservableObject {
    @Published var segmentationMask: UIImage? = nil
    private var isProcessing = false
    
    private lazy var visionModel: VNCoreMLModel? = {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        if let modelUrl = Bundle.main.url(forResource: "LiteSeg", withExtension: "mlmodelc"),
           let compiledModel = try? MLModel(contentsOf: modelUrl),
           let visionWrapper = try? VNCoreMLModel(for: compiledModel) {
            return visionWrapper
        }
        return nil
    }()
    
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        isProcessing = true
        
        if let model = visionModel {
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                defer { self?.isProcessing = false }
                guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                      let multiArray = results.first?.featureValue.multiArrayValue else { return }
                // Local fallback inference if required
            }
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        } else {
            isProcessing = false
        }
    }
}

import AVFoundation
import CoreImage
import CoreML
import Vision

/// A lightweight two-stage OCR pipeline using custom Core ML models (detector + recognizer).
///
/// This is intended for on-device use with mobile-friendly models (e.g., PaddleOCR mobile exports).
/// If the bundled models cannot be loaded, `isReady` will be `false` and callers should fall back to
/// the system Vision text recognizer.
final class CoreMLOCREngine {
    struct ModelNames {
        let detector: String
        let recognizer: String
    }

    private let detectorRequest: VNCoreMLRequest
    private let recognizerModel: VNCoreMLModel
    private let ciContext = CIContext()
    private let queue = DispatchQueue(label: "coreml.ocr.queue")
    private var isProcessing = false

    let isReady: Bool

    init?(modelNames: ModelNames, bundle: Bundle = .main) {
        guard let detectorURL = bundle.url(forResource: modelNames.detector, withExtension: "mlmodelc"),
              let recognizerURL = bundle.url(forResource: modelNames.recognizer, withExtension: "mlmodelc") else {
            isReady = false
            return nil
        }

        do {
            // Use Neural Engine where available for speed.
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine

            let detectorModel = try MLModel(contentsOf: detectorURL, configuration: configuration)
            let recognizerModelRaw = try MLModel(contentsOf: recognizerURL, configuration: configuration)

            let detectorVNModel = try VNCoreMLModel(for: detectorModel)
            recognizerModel = try VNCoreMLModel(for: recognizerModelRaw)

            detectorRequest = VNCoreMLRequest(model: detectorVNModel)
            detectorRequest.imageCropAndScaleOption = .scaleFit
            isReady = true
        } catch {
            isReady = false
            return nil
        }
    }

    /// Runs detection + recognition on the provided pixel buffer. The completion handler is invoked on the
    /// Core ML queue to avoid blocking the capture thread.
    func process(pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation,
                 completion: @escaping (Date, [String]) -> Void) {
        guard isReady, !isProcessing else { return }
        isProcessing = true

        let timestamp = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.detectorRequest])
                let textStrings = self.collectDetections(from: self.detectorRequest.results,
                                                         pixelBuffer: pixelBuffer,
                                                         orientation: orientation)
                completion(timestamp, textStrings)
            } catch {
                completion(timestamp, [])
            }
            self.isProcessing = false
        }
    }

    private func collectDetections(from results: [Any]?,
                                   pixelBuffer: CVPixelBuffer,
                                   orientation: CGImagePropertyOrientation) -> [String] {
        guard let observations = results as? [VNRecognizedObjectObservation], !observations.isEmpty else { return [] }

        var recognizedStrings: [String] = []
        for observation in observations {
            let box = observation.boundingBox
            guard let croppedImage = crop(pixelBuffer, to: box) else { continue }

            if let text = recognizeText(from: croppedImage, orientation: orientation) {
                recognizedStrings.append(text)
            }
        }
        return recognizedStrings
    }

    private func recognizeText(from cgImage: CGImage,
                               orientation: CGImagePropertyOrientation) -> String? {
        let request = VNCoreMLRequest(model: recognizerModel)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
            if let classifications = request.results as? [VNClassificationObservation],
               let best = classifications.max(by: { $0.confidence < $1.confidence }) {
                return best.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func crop(_ pixelBuffer: CVPixelBuffer, to boundingBox: CGRect) -> CGImage? {
        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rect = VNImageRectForNormalizedRect(boundingBox, Int(imageWidth), Int(imageHeight))

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: rect)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

import AVFoundation
import ImageIO
import CoreImage
import CoreML
import SwiftUI
import UIKit
import Vision

final class CameraViewModel: NSObject, ObservableObject {
    @Published var recognizedValue: Double?
    @Published var isReadingActive: Bool = false
    @Published var mean: Double = 0
    @Published var standardDeviation: Double = 0
    @Published var samples: [MeasurementSample] = []
    @Published var statusMessage: String = "Starting camera…"
    @Published var confidenceThreshold: VNConfidence = 1.0
    @Published var minimumTextHeight: Float = 0.1 // normalized 0..1
    @Published var windowDuration: TimeInterval = 5 // seconds

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue = DispatchQueue(label: "camera.vision.queue")
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isConfigured = false
    private var lastDetectionDate: Date?
    private let detectionStaleInterval: TimeInterval = 1.5
    private lazy var coreMLOCREngine: CoreMLOCREngine? = {
        CoreMLOCREngine(modelNames: .init(detector: "PPOCRv4TextDetector",
                                          recognizer: "PPOCRv4TextRecognizer"))
    }()
    private let enableCoreMLOCREngine = true

    private lazy var recognizeTextRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest(completionHandler: handleDetectedText)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = minimumTextHeight
        return request
    }()

    let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configureSessionIfNeeded() else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.statusMessage = "Looking for numbers…"
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.clearCurrentReading()
                self?.statusMessage = "Camera stopped."
            }
        }
    }

    private func configureSessionIfNeeded() -> Bool {
        guard !isConfigured else { return true }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in semaphore.signal() }
            semaphore.wait()
        default:
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Camera permission denied."
            }
            return false
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Camera unavailable."
            }
            return false
        }

        captureSession.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Unable to read camera frames."
            }
            return false
        }

        captureSession.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
            if connection.isVideoMirroringSupported {
                if connection.automaticallyAdjustsVideoMirroring {
                    connection.automaticallyAdjustsVideoMirroring = false
                }
                connection.isVideoMirrored = false
            }
        }

        captureSession.commitConfiguration()
        isConfigured = true
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "Camera ready."
        }
        return true
    }

    private func handleDetectedText(request: VNRequest, error: Error?) {
        guard error == nil,
              let observations = request.results as? [VNRecognizedTextObservation] else { return }

        var bestValue: (value: Double, confidence: VNConfidence)?

        for observation in observations {
            let candidates = observation.topCandidates(3)
            for candidate in candidates {
                guard candidate.confidence >= confidenceThreshold else { continue }
                let range = NSRange(location: 0, length: candidate.string.utf16.count)
                // Full string range used to anchor regex matching
                
                guard let value = validatedNumericValue(from: candidate.string, range: range) else { continue }

                if bestValue == nil || candidate.confidence > bestValue!.confidence {
                    bestValue = (value, candidate.confidence)
                }
            }
        }

        guard let accepted = bestValue else {
            DispatchQueue.main.async { [weak self] in
                self?.lastDetectionDate = nil
                self?.clearCurrentReading()
            }
            return
        }

        let detectionTime = Date()

        DispatchQueue.main.async { [weak self] in
            self?.lastDetectionDate = detectionTime
            self?.isReadingActive = true
            self?.updateStatistics(with: accepted.value)
            self?.statusMessage = "Tracking live samples."
            self?.scheduleStaleReset(at: detectionTime)
        }
    }

    private func handleRecognizedTextCandidates(_ candidates: [String], detectionTime: Date) {
        for candidate in candidates {
            let range = NSRange(location: 0, length: candidate.utf16.count)
            if let value = validatedNumericValue(from: candidate, range: range) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastDetectionDate = detectionTime
                    self.isReadingActive = true
                    self.updateStatistics(with: value)
                    self.statusMessage = "Tracking live samples (Core ML)."
                    self.scheduleStaleReset(at: detectionTime)
                }
                return
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastDetectionDate = nil
            self?.clearCurrentReading()
        }
    }

    private func validatedNumericValue(from string: String, range: NSRange) -> Double? {
        let decimalPattern = "^(?:0|[1-9]\\d*)\\.\\d{3}$"
        let regex = try? NSRegularExpression(pattern: decimalPattern)

        guard let match = regex?.firstMatch(in: string, range: range),
              match.range.location == 0,
              match.range.length == range.length,
              let value = Double(string) else { return nil }
        return value
    }

    private func updateStatistics(with value: Double) {
        recognizedValue = value
        samples.append(MeasurementSample(timestamp: Date(), value: value))

        let cutoff = Date().addingTimeInterval(-windowDuration)
        while let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }

        let values = samples.map { $0.value }
        let count = Double(values.count)
        guard count > 0 else { return }

        let total = values.reduce(0, +)
        mean = total / count

        let variance = values.reduce(0) { partial, current in
            let delta = current - mean
            return partial + delta * delta
        } / count

        standardDeviation = sqrt(variance)
    }

    private func scheduleStaleReset(at detectionTime: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + detectionStaleInterval) { [weak self] in
            guard let self else { return }
            guard self.lastDetectionDate == detectionTime else { return }
            self.clearCurrentReading()
        }
    }

    private func clearCurrentReading() {
        recognizedValue = nil
        isReadingActive = false
        lastDetectionDate = nil
        statusMessage = "Looking for numbers…"
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = currentImageOrientation(for: connection)

        if enableCoreMLOCREngine, let engine = coreMLOCREngine, engine.isReady {
            engine.process(pixelBuffer: pixelBuffer, orientation: orientation) { [weak self] timestamp, candidates in
                self?.handleRecognizedTextCandidates(candidates, detectionTime: timestamp)
            }
        } else {
            // Update recognition request parameters just-in-time
            recognizeTextRequest.minimumTextHeight = minimumTextHeight
            recognizeTextRequest.recognitionLanguages = ["en-US"]
            recognizeTextRequest.regionOfInterest = currentRegionOfInterest

            try? sequenceHandler.perform([recognizeTextRequest], on: pixelBuffer, orientation: orientation)
        }
    }
}

struct MeasurementSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

extension CGImagePropertyOrientation {
    init(_ orientation: AVCaptureVideoOrientation) {
        switch orientation {
        case .portrait:
            self = .right
        case .portraitUpsideDown:
            self = .left
        case .landscapeRight:
            self = .down
        case .landscapeLeft:
            self = .up
        @unknown default:
            self = .right
        }
    }
}

extension CameraViewModel {
    /// Derives the correct CGImagePropertyOrientation for Vision based on the capture connection and interface/device orientation.
    fileprivate func currentImageOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        // Prefer the video orientation from the capture connection when available
        if connection.isVideoOrientationSupported {
            switch connection.videoOrientation {
            case .portrait: return .right
            case .portraitUpsideDown: return .left
            case .landscapeRight: return .down
            case .landscapeLeft: return .up
            @unknown default: return .right
            }
        }
        // Fallback: derive from interface orientation if possible (iOS only)
        #if os(iOS)
        let interfaceOrientation: UIInterfaceOrientation? = {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                return windowScene.interfaceOrientation
            }
            return nil
        }()
        if let io = interfaceOrientation {
            switch io {
            case .portrait: return .right
            case .portraitUpsideDown: return .left
            case .landscapeLeft: return .up
            case .landscapeRight: return .down
            default: break
            }
        }

        // Fallback to device orientation as a last resort
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
        #else
        return .right
        #endif
    }
}

extension CameraViewModel {
    /// Normalized ROI in Vision’s image coordinate space (0..1)
    var currentRegionOfInterest: CGRect {
        // Always use center band ROI
        return CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.3)
    }
}

// MARK: - Core ML OCR Engine (on-device, detector + recognizer)

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

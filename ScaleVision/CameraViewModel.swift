import AVFoundation
import CoreImage
import ImageIO
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
    private let ciContext = CIContext()
    private var isConfigured = false
    private var lastDetectionDate: Date?
    private let detectionStaleInterval: TimeInterval = 1.5
    private let ocrClient = PaddleOCRClient()
    private let ocrThrottleInterval: TimeInterval = 0.6
    private var lastOCRRequestDate: Date?
    private var ocrInFlight = false

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
                self.statusMessage = "Looking for numbers with PaddleOCR…"
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
        statusMessage = "Looking for numbers with PaddleOCR…"
    }

    private func shouldIssueOCRRequest() -> Bool {
        if ocrInFlight { return false }
        if let last = lastOCRRequestDate, Date().timeIntervalSince(last) < ocrThrottleInterval {
            return false
        }
        return true
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private func crop(image: CGImage, to normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // Vision normalized coordinates originate in the lower-left; CGImage uses upper-left
        let adjustedRect = CGRect(
            x: normalizedRect.origin.x * width,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        ).integral

        let boundedRect = adjustedRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !boundedRect.isNull, let cropped = image.cropping(to: boundedRect) else {
            return nil
        }
        return cropped
    }

    private func handleRecognizedCandidates(_ candidates: [PaddleOCRCandidate]) {
        let decimalPattern = "^(?:0|[1-9]\\d*)\\.\\d{3}$"
        let regex = try? NSRegularExpression(pattern: decimalPattern)

        var bestValue: (value: Double, confidence: VNConfidence)?

        for candidate in candidates {
            let confidence = VNConfidence(candidate.confidence)
            guard confidence >= confidenceThreshold else { continue }

            let range = NSRange(location: 0, length: candidate.text.utf16.count)
            guard let match = regex?.firstMatch(in: candidate.text, range: range),
                  match.range.location == 0,
                  match.range.length == range.length,
                  let value = Double(candidate.text) else { continue }

            if bestValue == nil || confidence > bestValue!.confidence {
                bestValue = (value, confidence)
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
            self?.statusMessage = "Tracking live samples (PaddleOCR)."
            self?.scheduleStaleReset(at: detectionTime)
        }
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = currentImageOrientation(for: connection)

        guard shouldIssueOCRRequest() else { return }
        guard let cgImage = makeCGImage(from: pixelBuffer, orientation: orientation) else { return }
        let roiImage = crop(image: cgImage, to: currentRegionOfInterest) ?? cgImage
        ocrInFlight = true
        lastOCRRequestDate = Date()
        ocrClient.recognizeText(in: roiImage) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.ocrInFlight = false
            }
            switch result {
            case .success(let candidates):
                self.handleRecognizedCandidates(candidates)
            case .failure:
                DispatchQueue.main.async {
                    self.statusMessage = "Waiting for PaddleOCR…"
                }
            }
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

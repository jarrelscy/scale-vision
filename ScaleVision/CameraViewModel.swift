import AVFoundation
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
    private var isConfigured = false
    private var lastDetectionDate: Date?
    private let detectionStaleInterval: TimeInterval = 1.5

    private lazy var recognizeTextRequest: RecognizeTextRequest = {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.regionOfInterest = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
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

    private func handleDetectedText(_ observations: [RecognizedTextObservation]) {
        
        let decimalPattern = "^(?:0|[1-9]\\d*)\\.\\d{3}$"
        let regex = try? NSRegularExpression(pattern: decimalPattern)

        var bestValue: (value: Double, confidence: VNConfidence)?

        for observation in observations {
            let candidates = observation.topCandidates(3)
            for candidate in candidates {
                guard candidate.confidence >= confidenceThreshold else { continue }
                let range = NSRange(location: 0, length: candidate.string.utf16.count)
                // Full string range used to anchor regex matching
                
                guard let match = regex?.firstMatch(in: candidate.string, range: range),
                      match.range.location == 0,
                      match.range.length == range.length,
                      let value = Double(candidate.string) else { continue }

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

        // Update recognition request parameters just-in-time
        recognizeTextRequest.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        recognizeTextRequest.regionOfInterest = NormalizedRect(currentRegionOfInterest)

        let handler = ImageRequestHandler(buffer: pixelBuffer, orientation: orientation)
        do {
            let observations: [RecognizedTextObservation] = try handler.perform([recognizeTextRequest])
            handleDetectedText(observations)
        } catch {
            // Ignore frame on failure
            return
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
        // Use a centered square-ish region to cover more of the frame
        return CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    }
}

extension NormalizedRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

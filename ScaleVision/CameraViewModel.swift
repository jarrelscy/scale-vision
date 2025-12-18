import AVFoundation
import ImageIO
import SwiftUI
import Vision

final class CameraViewModel: NSObject, ObservableObject {
    @Published var recognizedValue: Double?
    @Published var recognizedBoundingBox: CGRect?
    @Published var videoDimensions: CGSize = .zero
    @Published var isReadingActive: Bool = false
    @Published var mean: Double = 0
    @Published var standardDeviation: Double = 0
    @Published var samples: [MeasurementSample] = []
    @Published var statusMessage: String = "Starting camera…"

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue = DispatchQueue(label: "camera.vision.queue")
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isConfigured = false
    private var lastDetectionDate: Date?
    private let detectionStaleInterval: TimeInterval = 1.5

    private lazy var recognizeTextRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest(completionHandler: handleDetectedText)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
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
            connection.videoOrientation = .portrait
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

        let decimalPattern = "\\d+\\.\\d+"
        let regex = try? NSRegularExpression(pattern: decimalPattern)

        var bestValue: Double?
        var bestBox: CGRect?

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let range = NSRange(location: 0, length: candidate.string.utf16.count)
            guard let match = regex?.firstMatch(in: candidate.string, range: range),
                  let swiftRange = Range(match.range, in: candidate.string),
                  let value = Double(candidate.string[swiftRange]) else { continue }
            bestValue = value
            bestBox = observation.boundingBox
            break
        }

        guard let value = bestValue else {
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
            self?.updateStatistics(with: value)
            self?.recognizedBoundingBox = bestBox
            self?.statusMessage = "Tracking live samples."
            self?.scheduleStaleReset(at: detectionTime)
        }
    }

    private func updateStatistics(with value: Double) {
        recognizedValue = value
        samples.append(MeasurementSample(timestamp: Date(), value: value))

        if samples.count > 300 {
            samples.removeFirst(samples.count - 300)
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
        recognizedBoundingBox = nil
        recognizedValue = nil
        isReadingActive = false
        lastDetectionDate = nil
        statusMessage = "Looking for numbers…"
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = CGImagePropertyOrientation(connection.videoOrientation)
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let pixelSize = CGSize(width: width, height: height)

        DispatchQueue.main.async { [weak self] in
            if self?.videoDimensions != pixelSize {
                self?.videoDimensions = pixelSize
            }
        }

        try? sequenceHandler.perform([recognizeTextRequest], on: pixelBuffer, orientation: orientation)
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

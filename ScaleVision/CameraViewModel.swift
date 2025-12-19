import AVFoundation
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM
import SwiftUI
import UIKit

final class CameraViewModel: NSObject, ObservableObject {
    @Published var recognizedValue: Double?
    @Published var isReadingActive: Bool = false
    @Published var mean: Double = 0
    @Published var standardDeviation: Double = 0
    @Published var samples: [MeasurementSample] = []
    @Published var statusMessage: String = "Starting camera…"
    @Published var modelInfo: String = "Preparing smolvlm2…"
    @Published var windowDuration: TimeInterval = 5 // seconds

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let inferenceQueue = DispatchQueue(label: "camera.vlm.queue")
    private var isConfigured = false
    private var lastDetectionDate: Date?
    private let detectionStaleInterval: TimeInterval = 3.0

    private let inferencePrompt = "What decimal number is shown on the LED display here? Return the number alone and nothing else."
    private let inferenceInterval: TimeInterval = 2.0
    private var isProcessingFrame = false
    private var lastInferenceDate: Date?
    private var modelLoadTask: Task<ModelContainer, Error>?
    private var generationTask: Task<Void, Never>?

    private let generateParameters = MLXLMCommon.GenerateParameters(
        maxTokens: 24, temperature: 0.0, topP: 0.9
    )

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
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.loadModelIfNeeded()
            }
            DispatchQueue.main.async {
                self.statusMessage = "Model loading…"
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            self?.generationTask?.cancel()
            self?.isProcessingFrame = false
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
        videoOutput.setSampleBufferDelegate(self, queue: inferenceQueue)
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

    private func loadModelIfNeeded() async throws -> ModelContainer {
        if let modelLoadTask {
            return try await modelLoadTask.value
        }

        let configuration = VLMRegistry.smolvlm2

        let task = Task { () async throws -> ModelContainer in
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            return try await VLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.modelInfo = "Downloading \(configuration.name): \(Int(progress.fractionCompleted * 100))%"
                    self?.statusMessage = "Downloading smolvlm2…"
                }
            }
        }
        modelLoadTask = task

        do {
            let container = try await task.value
            let numParams = await container.perform { context in
                context.model.numParameters()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelInfo = "Loaded \(configuration.id) — \(numParams / (1024 * 1024))M params"
                if self.captureSession.isRunning {
                    self.statusMessage = "Model ready. Looking for numbers…"
                }
            }
            return container
        } catch {
            await MainActor.run { [weak self] in
                self?.modelInfo = "Failed to load smolvlm2"
                self?.statusMessage = "Model load failed."
            }
            modelLoadTask = nil
            throw error
        }
    }

    private func runInference(on image: CIImage) async {
        let detectionTime = Date()
        do {
            let value = try await recognizeValue(in: image)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessingFrame = false
                if let value {
                    self.lastDetectionDate = detectionTime
                    self.isReadingActive = true
                    self.updateStatistics(with: value)
                    self.statusMessage = "Tracking live samples."
                    self.scheduleStaleReset(at: detectionTime)
                } else {
                    self.clearCurrentReading()
                }
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.isProcessingFrame = false
                self?.statusMessage = "Inference failed: \(error.localizedDescription)"
            }
        }
    }

    private func recognizeValue(in ciImage: CIImage) async throws -> Double? {
        let container = try await loadModelIfNeeded()
        let prompt = inferencePrompt
        let parameters = generateParameters

        let response = try await container.perform { (context: ModelContext) -> String in
            var userInput = UserInput(chat: [
                .system("You read decimal numbers from LED displays."),
                .user(prompt, images: [.ciImage(ciImage)])
            ])
            userInput.processing.resize = .init(width: 448, height: 448)

            let input = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            )

            var output = ""
            for try await generation in stream {
                if let chunk = generation.chunk {
                    output += chunk
                }
            }
            return output
        }

        return parseNumber(from: response)
    }

    private func parseNumber(from response: String) -> Double? {
        let sanitized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[0-9]+\\.[0-9]+"
        if let range = sanitized.range(of: pattern, options: .regularExpression) {
            return Double(String(sanitized[range]))
        }
        return Double(sanitized)
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
        statusMessage = "Waiting for VLM detection…"
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()
        if isProcessingFrame || (lastInferenceDate != nil && now.timeIntervalSince(lastInferenceDate!) < inferenceInterval) {
            return
        }

        lastInferenceDate = now
        isProcessingFrame = true

        let orientation = currentImageOrientation(for: connection)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))

        generationTask = Task(priority: .userInitiated) { [weak self] in
            await self?.runInference(on: ciImage)
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
    fileprivate func currentImageOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        if connection.isVideoOrientationSupported {
            switch connection.videoOrientation {
            case .portrait: return .right
            case .portraitUpsideDown: return .left
            case .landscapeRight: return .down
            case .landscapeLeft: return .up
            @unknown default: return .right
            }
        }

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

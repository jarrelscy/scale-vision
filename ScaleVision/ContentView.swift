import SwiftUI
import AVFoundation
import Vision

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()
                .onAppear { viewModel.startSession() }
                .onDisappear { viewModel.stopSession() }
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        if let box = viewModel.recognizedBoundingBox,
                           let rect = boundingBoxRect(box, in: geometry.size, videoSize: viewModel.videoDimensions) {
                            Rectangle()
                                .stroke(Color.yellow, lineWidth: 3)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .shadow(color: .black.opacity(0.3), radius: 4)
                                .accessibilityLabel("Recognized text bounding box")
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                Text("Live OCR")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)
                    .shadow(radius: 4)

                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))

                if let value = viewModel.recognizedValue {
                    Text("Latest: " + viewModel.numberFormatter.string(from: NSNumber(value: value))!)
                } else {
                    Text("Latest: --")
                }

                if viewModel.isReadingActive {
                    Text("Mean: " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.mean))!)
                    Text("Std Dev: " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.standardDeviation))!)
                } else {
                    Text("Mean (paused): " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.mean))!)
                    Text("Std Dev (paused): " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.standardDeviation))!)
                }
            }
            .padding()
            .background(Color.black.opacity(0.4))
            .cornerRadius(12)
            .padding()
            .foregroundColor(.white)

            VStack {
                Spacer()
                TrendGraphView(samples: viewModel.samples, isPaused: !viewModel.isReadingActive)
                    .frame(height: 160)
                    .padding()
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

private func boundingBoxRect(_ normalizedBox: CGRect, in viewSize: CGSize, videoSize: CGSize) -> CGRect? {
    guard videoSize.width > 0, videoSize.height > 0 else { return nil }

    let imageRect = VNImageRectForNormalizedRect(normalizedBox, Int(videoSize.width), Int(videoSize.height))

    let scale = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
    let scaledVideoSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    let xOffset = (scaledVideoSize.width - viewSize.width) / 2
    let yOffset = (scaledVideoSize.height - viewSize.height) / 2

    let originX = imageRect.minX * scale - xOffset
    let originY = (scaledVideoSize.height - (imageRect.maxY * scale)) - yOffset
    let width = imageRect.width * scale
    let height = imageRect.height * scale

    guard width > 0, height > 0 else { return nil }

    return CGRect(x: originX, y: originY, width: width, height: height)
}

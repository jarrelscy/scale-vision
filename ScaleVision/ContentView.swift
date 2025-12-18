import SwiftUI
import AVFoundation

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

    let viewAspect = viewSize.width / viewSize.height
    let videoAspect = videoSize.width / videoSize.height

    if viewAspect > videoAspect {
        let scaledHeight = viewSize.width / videoAspect
        let yOffset = (scaledHeight - viewSize.height) / 2
        return CGRect(
            x: normalizedBox.minX * viewSize.width,
            y: (1 - normalizedBox.maxY) * scaledHeight - yOffset,
            width: normalizedBox.width * viewSize.width,
            height: normalizedBox.height * scaledHeight
        )
    } else {
        let scaledWidth = viewSize.height * videoAspect
        let xOffset = (scaledWidth - viewSize.width) / 2
        return CGRect(
            x: normalizedBox.minX * scaledWidth - xOffset,
            y: (1 - normalizedBox.maxY) * viewSize.height,
            width: normalizedBox.width * scaledWidth,
            height: normalizedBox.height * viewSize.height
        )
    }
}

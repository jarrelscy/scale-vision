import SwiftUI
import AVFoundation
import Vision

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        let percentFormatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .percent
            f.maximumFractionDigits = 0
            return f
        }()

        ZStack(alignment: .topLeading) {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()
                .onAppear { viewModel.startSession() }
                .onDisappear { viewModel.stopSession() }

            HStack(alignment: .top, spacing: 16) {
                // Left control panel
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

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Confidence threshold")
                                .font(.subheadline)
                            Spacer()
                            Text(percentFormatter.string(from: NSNumber(value: viewModel.confidenceThreshold)) ?? "")
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(viewModel.confidenceThreshold) },
                            set: { viewModel.confidenceThreshold = VNConfidence($0) }
                        ), in: 0.0...1.0, step: 0.01)
                    }

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Min text height")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f", viewModel.minimumTextHeight))
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                        Slider(value: $viewModel.minimumTextHeight, in: 0.0...0.1, step: 0.001)
                    }

                    Divider().padding(.vertical, 4)

                    // Averaging window control
                    CameraControlsView(windowDuration: $viewModel.windowDuration)
                }
                .padding()
                .background(Color.black.opacity(0.4))
                .cornerRadius(12)
                .foregroundColor(.white)
                .frame(maxWidth: 360, alignment: .leading)

                Spacer()

                // Right: trend graph at top-right
                VStack {
                    TrendGraphView(samples: viewModel.samples, isPaused: !viewModel.isReadingActive)
                        .frame(width: 420, height: 220)
                        .padding()
                    Spacer()
                }
            }
            .padding()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

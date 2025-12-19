import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()
                .onAppear { viewModel.startSession() }
                .onDisappear { viewModel.stopSession() }

            HStack(alignment: .top, spacing: 16) {
                // Left control panel
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live VLM")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                        .shadow(radius: 4)

                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))

                    Text(viewModel.modelInfo)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))

                    Text("Prompt: \"What decimal number is shown on the LED display here? Return the number alone and nothing else.\"")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 2)

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

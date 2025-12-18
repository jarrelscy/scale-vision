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

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
                        if let box = viewModel.recognizedBoundingBox {
                            let rect = CGRect(
                                x: box.minX * geometry.size.width,
                                y: (1 - box.maxY) * geometry.size.height,
                                width: box.width * geometry.size.width,
                                height: box.height * geometry.size.height
                            )

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

                Text("Mean: " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.mean))!)
                Text("Std Dev: " + viewModel.numberFormatter.string(from: NSNumber(value: viewModel.standardDeviation))!)
            }
            .padding()
            .background(Color.black.opacity(0.4))
            .cornerRadius(12)
            .padding()
            .foregroundColor(.white)

            VStack {
                Spacer()
                TrendGraphView(samples: viewModel.samples)
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

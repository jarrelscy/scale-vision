import SwiftUI

struct CameraControlsView: View {
    @Binding var windowDuration: TimeInterval

    // Reasonable bounds for the sliding window in seconds
    private let range: ClosedRange<Double> = 1...30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Averaging Window")
                .font(.headline)

            HStack {
                Slider(value: $windowDuration, in: range, step: 1) {
                    Text("Window (s)")
                }
                .accessibilityLabel("Window duration in seconds")

                Text("\(Int(windowDuration))s")
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .padding(.top, 4)

            Text("Controls the length of the sliding window used to compute mean and standard deviation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    @State var duration: TimeInterval = 5
    return CameraControlsView(windowDuration: $duration)
}

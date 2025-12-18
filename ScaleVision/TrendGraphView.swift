import SwiftUI

struct TrendGraphView: View {
    let samples: [MeasurementSample]
    let isPaused: Bool
    private let sampleWindow: TimeInterval = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trend")
                .font(.headline)
                .foregroundColor(.white)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.35))
                    if prunedSamples.isEmpty {
                        Text("Waiting for OCR samples…")
                            .foregroundColor(.white.opacity(0.7))
                    } else if isPaused {
                        graphPath(in: geometry)
                            .opacity(0.3)
                        Text("Trend paused — no OCR detected")
                            .font(.footnote)
                            .foregroundColor(.white)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            graphPath(in: geometry)
                        }
                    }
                }
            }

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 32)
                Spacer()
                Text("Time")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.trailing, 4)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.35))
        .cornerRadius(16)
    }
}

struct TrendGraphView_Previews: PreviewProvider {
    static var previews: some View {
        TrendGraphView(samples: [
            MeasurementSample(timestamp: Date().addingTimeInterval(-5), value: 12.301),
            MeasurementSample(timestamp: Date().addingTimeInterval(-3), value: 12.351),
            MeasurementSample(timestamp: Date(), value: 12.333)
        ], isPaused: false)
        .frame(height: 200)
        .preferredColorScheme(.dark)
    }
}

private extension TrendGraphView {
    var prunedSamples: [MeasurementSample] {
        let cutoff = Date().addingTimeInterval(-sampleWindow)
        return samples.filter { $0.timestamp >= cutoff }
    }

    @ViewBuilder
    func graphPath(in geometry: GeometryProxy) -> some View {
        Path { path in
            let times = prunedSamples.map { $0.timestamp.timeIntervalSince1970 }
            let values = prunedSamples.map { $0.value }

            guard let minTime = times.min(),
                  let maxTime = times.max(),
                  let minValue = values.min(),
                  let maxValue = values.max(),
                  maxTime > minTime else {
                if prunedSamples.first != nil {
                    let x = geometry.size.width / 2
                    let y = geometry.size.height / 2
                    path.move(to: CGPoint(x: x, y: y))
                    path.addEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + 0.01, y: y))
                }
                return
            }

            let timeRange = maxTime - minTime
            let valueRange = max(maxValue - minValue, 0.0001)

            func xPosition(for time: TimeInterval) -> CGFloat {
                let normalized = (time - minTime) / timeRange
                return CGFloat(normalized) * geometry.size.width
            }

            func yPosition(for value: Double) -> CGFloat {
                let normalized = (value - minValue) / valueRange
                return geometry.size.height - CGFloat(normalized) * geometry.size.height
            }

            let first = prunedSamples.first!
            path.move(to: CGPoint(x: xPosition(for: first.timestamp.timeIntervalSince1970),
                                  y: yPosition(for: first.value)))

            for sample in prunedSamples.dropFirst() {
                path.addLine(to: CGPoint(x: xPosition(for: sample.timestamp.timeIntervalSince1970),
                                         y: yPosition(for: sample.value)))
            }
        }
        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

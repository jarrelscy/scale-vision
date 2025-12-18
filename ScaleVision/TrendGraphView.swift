import SwiftUI

struct TrendGraphView: View {
    let samples: [MeasurementSample]
    let isPaused: Bool
    private let sampleWindow: TimeInterval = 5
    private let tickFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

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
                        gridOverlay(in: geometry)
                        graphPath(in: geometry)
                            .opacity(0.3)
                        Text("Trend paused — no OCR detected")
                            .font(.footnote)
                            .foregroundColor(.white)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            ZStack {
                                gridOverlay(in: geometry)
                                graphPath(in: geometry)
                            }
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

    struct GraphMetrics {
        let minTime: TimeInterval
        let maxTime: TimeInterval
        let minValue: Double
        let maxValue: Double
        let ticks: [Double]
    }

    func metrics() -> GraphMetrics? {
        let times = prunedSamples.map { $0.timestamp.timeIntervalSince1970 }
        let values = prunedSamples.map { $0.value }

        guard let minTime = times.min(),
              let maxTime = times.max(),
              let minValue = values.min(),
              let maxValue = values.max(),
              maxTime > minTime else {
            return nil
        }

        let valueRange = max(maxValue - minValue, 0.0001)
        let midValue = minValue + valueRange / 2
        let ticks: [Double]
        if valueRange < 0.0001 {
            ticks = [minValue]
        } else {
            ticks = [minValue, midValue, maxValue]
        }

        return GraphMetrics(minTime: minTime, maxTime: maxTime, minValue: minValue, maxValue: maxValue, ticks: ticks)
    }

    @ViewBuilder
    func graphPath(in geometry: GeometryProxy) -> some View {
        Path { path in
            guard let metrics = metrics() else { return }
            let positions = positionFunctions(for: metrics, in: geometry.size)

            let first = prunedSamples.first!
            path.move(to: CGPoint(x: positions.x(first.timestamp.timeIntervalSince1970),
                                  y: positions.y(first.value)))

            for sample in prunedSamples.dropFirst() {
                path.addLine(to: CGPoint(x: positions.x(sample.timestamp.timeIntervalSince1970),
                                         y: positions.y(sample.value)))
            }
        }
        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    @ViewBuilder
    func gridOverlay(in geometry: GeometryProxy) -> some View {
        if let metrics = metrics() {
            let positions = positionFunctions(for: metrics, in: geometry.size)
            ZStack(alignment: .leading) {
                ForEach(metrics.ticks, id: \.self) { tick in
                    let y = positions.y(tick)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Text(tickFormatter.string(from: NSNumber(value: tick)) ?? "")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .position(x: 32, y: y - 8)
                }

                HStack {
                    Text(timeLabel(for: metrics.minTime, relativeTo: metrics.maxTime))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("now")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    func positionFunctions(for metrics: GraphMetrics, in size: CGSize) -> (x: (TimeInterval) -> CGFloat, y: (Double) -> CGFloat) {
        let timeRange = metrics.maxTime - metrics.minTime
        let valueRange = max(metrics.maxValue - metrics.minValue, 0.0001)

        func xPosition(for time: TimeInterval) -> CGFloat {
            let normalized = (time - metrics.minTime) / timeRange
            return CGFloat(normalized) * size.width
        }

        func yPosition(for value: Double) -> CGFloat {
            let normalized = (value - metrics.minValue) / valueRange
            return size.height - CGFloat(normalized) * size.height
        }

        return (xPosition, yPosition)
    }

    func timeLabel(for minTime: TimeInterval, relativeTo maxTime: TimeInterval) -> String {
        let delta = maxTime - minTime
        return String(format: "-%0.1fs", delta)
    }
}

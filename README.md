# Scale Vision

A single-screen iOS app that streams the camera feed, queries the MLX `smolvlm2` vision-language model to read the decimal value shown on an LED display, and overlays running statistics plus a trend chart of the detected values.

## Features
- Live camera preview with MLX `smolvlm2` VLM inference tuned for decimal numbers (e.g., `xx.yyy`).
- Displays the latest reading, running mean, and standard deviation directly on the video feed.
- Scrolls a live graph of the readings versus time on the same screen.

## Project structure
- `ScaleVisionApp.swift`: App entry point.
- `ContentView.swift`: Main UI composition with overlays and graph.
- `CameraViewModel.swift`: Capture session management, MLX VLM inference, and running statistics.
- `CameraPreviewView.swift`: UIKit wrapper to present the capture session in SwiftUI.
- `TrendGraphView.swift`: Lightweight Sparkline-style chart of recent readings.
- `Info.plist`: Configuration and camera usage description.

## Usage
Open the project in Xcode, ensure camera permissions are granted on device, and run on an iPhone. The overlay updates as the electronic readout changes.

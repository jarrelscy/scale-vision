# Scale Vision

A single-screen iOS app that streams the camera feed, performs OCR on an electronic readout using a PaddleOCR inference endpoint, and overlays running statistics plus a trend chart of the detected values.

## Features
- Live camera preview with PaddleOCR text recognition tuned for decimal numbers (e.g., `xx.yyy`).
- Displays the latest reading, running mean, and standard deviation directly on the video feed.
- Scrolls a live graph of the readings versus time on the same screen.

## Project structure
- `ScaleVisionApp.swift`: App entry point.
- `ContentView.swift`: Main UI composition with overlays and graph.
- `CameraViewModel.swift`: Capture session management, PaddleOCR integration, and running statistics.
- `CameraPreviewView.swift`: UIKit wrapper to present the capture session in SwiftUI.
- `TrendGraphView.swift`: Lightweight Sparkline-style chart of recent readings.
- `Info.plist`: Configuration and camera usage description.

## Usage
Run a PaddleOCR HTTP server (default: `http://localhost:8866/predict/ocr_system`, the standard serving address for the official Docker image) accessible from the device. Then open the project in Xcode, ensure camera permissions are granted on device, and run on an iPhone. The overlay updates as the electronic readout changes.

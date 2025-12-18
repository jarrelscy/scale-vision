# Scale Vision

A single-screen iOS app that streams the camera feed, performs OCR on an electronic readout using Apple Vision (with an optional Core ML OCR pipeline), and overlays running statistics plus a trend chart of the detected values.

## Features
- Live camera preview with text recognition tuned for decimal numbers (e.g., `xx.yyy`).
- Displays the latest reading, running mean, and standard deviation directly on the video feed.
- Scrolls a live graph of the readings versus time on the same screen.

## Project structure
- `ScaleVisionApp.swift`: App entry point.
- `ContentView.swift`: Main UI composition with overlays and graph.
- `CameraViewModel.swift`: Capture session management, Vision/Core ML OCR selection, and running statistics.
- `CameraPreviewView.swift`: UIKit wrapper to present the capture session in SwiftUI.
- `TrendGraphView.swift`: Lightweight Sparkline-style chart of recent readings.
- `Info.plist`: Configuration and camera usage description.

## Core ML OCR (on-device) option
- The app can automatically use bundled Core ML OCR models (detector + recognizer) named `PPOCRv4TextDetector.mlmodelc` and `PPOCRv4TextRecognizer.mlmodelc` if they are present in the app bundle. These should be mobile-friendly models (e.g., PaddleOCR mobile exports) compiled to `.mlmodelc`.
- If the models are missing or fail to load, the app seamlessly falls back to Apple Vision OCR.

## Usage
Open the project in Xcode, ensure camera permissions are granted on device, and run on an iPhone. The overlay updates as the electronic readout changes.

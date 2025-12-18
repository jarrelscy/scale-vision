import CoreGraphics
import Foundation
import UIKit

struct PaddleOCRCandidate: Decodable {
    let text: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case text
        case confidence = "score"
        case probability
    }

    init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        confidence = (try? container.decode(Double.self, forKey: .confidence)) ??
            (try? container.decode(Double.self, forKey: .probability)) ?? 0
    }
}

private struct PaddleOCRRequestPayload: Encodable {
    let image: String
    let useAngleCls: Bool
    let lang: String
}

private struct PaddleOCRResponse: Decodable {
    let predictions: [PaddleOCRCandidate]

    enum CodingKeys: String, CodingKey {
        case results
        case data
        case result
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            if let parsed = try? keyed.decode([PaddleOCRCandidate].self, forKey: .results) {
                predictions = parsed
                return
            }
            if let parsed = try? keyed.decode([PaddleOCRCandidate].self, forKey: .result) {
                predictions = parsed
                return
            }
            if let parsed = try? keyed.decode([[PaddleOCRCandidate]].self, forKey: .data), let first = parsed.first {
                predictions = first
                return
            }
            if let parsed = try? keyed.decode([PaddleOCRCandidate].self, forKey: .data) {
                predictions = parsed
                return
            }
        }

        predictions = try decoder.singleValueContainer().decode([PaddleOCRCandidate].self)
    }
}

enum PaddleOCRError: Error {
    case encodingFailure
    case emptyResponse
    case networkFailure
}

final class PaddleOCRClient {
    private let session: URLSession
    private let endpoint: URL

    init(endpoint: URL = URL(string: "http://localhost:8866/predict/ocr_system")!, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func recognizeText(in image: CGImage, completion: @escaping (Result<[PaddleOCRCandidate], Error>) -> Void) {
        guard let jpegData = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            completion(.failure(PaddleOCRError.encodingFailure))
            return
        }

        let payload = PaddleOCRRequestPayload(image: jpegData.base64EncodedString(), useAngleCls: true, lang: "en")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let data else {
                completion(.failure(PaddleOCRError.networkFailure))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(PaddleOCRResponse.self, from: data)
                guard !decoded.predictions.isEmpty else {
                    completion(.failure(PaddleOCRError.emptyResponse))
                    return
                }
                completion(.success(decoded.predictions))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

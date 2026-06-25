import Foundation

struct GemmaModel: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct GemmaClient {
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    func generate(prompt: String, model: GemmaModel) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(model: model.id, prompt: prompt, stream: false)
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GemmaClientError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)
                throw GemmaClientError.requestFailed(statusCode: httpResponse.statusCode, message: message)
            }

            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                throw GemmaClientError.serverUnavailable
            default:
                throw GemmaClientError.transportFailed(message: error.localizedDescription)
            }
        }
    }
}

private struct GenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct GenerateResponse: Decodable {
    let response: String
}

enum GemmaClientError: LocalizedError {
    case serverUnavailable
    case invalidResponse
    case requestFailed(statusCode: Int, message: String?)
    case transportFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "ローカルGemmaに接続できません。ターミナルで `ollama run gemma4` などを起動してから再試行してください。接続先は 127.0.0.1:11434 です。"
        case .invalidResponse:
            return "Gemmaから正しい応答が返りませんでした。"
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty {
                return "Gemmaへの送信に失敗しました。HTTP \(statusCode): \(message)"
            }
            return "Gemmaへの送信に失敗しました。HTTP \(statusCode)"
        case let .transportFailed(message):
            return "Gemmaへの接続でエラーが発生しました: \(message)"
        }
    }
}

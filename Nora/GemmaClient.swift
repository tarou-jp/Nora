import AppKit
import Foundation

struct GemmaModel: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct OllamaChatMessage: Encodable {
    let role: String
    let content: String
    var images: [String]?
}

extension NSImage {
    func jpegBase64(quality: CGFloat = 0.85) -> String? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { return nil }
        return jpeg.base64EncodedString()
    }
}

struct GemmaClient {
    private let chatEndpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    private let tagsEndpoint = URL(string: "http://127.0.0.1:11434/api/tags")!

    func fetchModels() async throws -> [GemmaModel] {
        let (data, _) = try await URLSession.shared.data(from: tagsEndpoint)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { GemmaModel(id: $0.model, displayName: Self.shortName($0.name)) }
    }

    private static func shortName(_ name: String) -> String {
        let parts = name.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return name }
        let tag = String(parts[1])
        return tag == "latest" ? String(parts[0]) : tag
    }

    func chat(messages: [OllamaChatMessage], model: GemmaModel) async throws -> String {
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model.id, messages: messages, stream: false)
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

            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct TagsResponse: Decodable {
    let models: [TagsModel]
}

private struct TagsModel: Decodable {
    let name: String
    let model: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
}

private struct ChatResponse: Decodable {
    let message: ChatResponseMessage
}

private struct ChatResponseMessage: Decodable {
    let content: String
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

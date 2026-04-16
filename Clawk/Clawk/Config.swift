import Foundation
import SwiftUI

enum Config {
    static let defaultGatewayBaseURL = "https://rare-lark.agent4.near.ai/"
    static let defaultGatewayToken = "b5af51dc17344eab80981e47f5ab5784a0f1df4846e7229fba421ae97021aa1e"

    private static var gatewayFallbackURL: String {
        let storedGateway = UserDefaults.standard.string(forKey: "gatewayHost")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedGateway, !storedGateway.isEmpty {
            return storedGateway
        }
        return defaultGatewayBaseURL
    }

    static var relayBaseURL: String {
        let storedRelay = UserDefaults.standard.string(forKey: "relayBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedRelay, !storedRelay.isEmpty {
            return storedRelay
        }
        return gatewayFallbackURL
    }

    static var isRelayEnabled: Bool {
        let storedRelay = UserDefaults.standard.string(forKey: "relayBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedRelay?.isEmpty == false
    }

    static var baseURL: String { relayBaseURL }

    static func persistRelayBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "relayBaseURL")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "relayBaseURL")
        }
    }

    static var websocketURL: URL {
        var components = URLComponents(string: relayBaseURL)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: deviceToken)]
        return components.url!
    }

    static var apiURL: URL {
        URL(string: relayBaseURL)!
    }

    static var usesLegacyLocalRelayDefault: Bool {
        relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("localhost")
            || relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).contains("127.0.0.1")
    }

    // Generate once and store in UserDefaults for the legacy relay channel.
    static let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") ?? {
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: "deviceToken")
        return token
    }()
}

// MARK: - Color Extensions

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

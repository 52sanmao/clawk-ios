import Foundation
import SwiftUI

enum Config {
    // Legacy relay backend kept separate from the primary OpenClaw gateway connection.
    static let relayBaseURL = UserDefaults.standard.string(forKey: "relayBaseURL") ?? "http://localhost:3002"

    static var baseURL: String { relayBaseURL }

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

import Foundation

enum T3PairingInput {
    static let maximumLength = 4_096
    private static let pairingSchemes = ["http", "https", "t3code", "t3code-dev"]

    static func credential(from pasted: String) -> String? {
        guard pasted.utf8.count <= maximumLength else { return nil }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           pairingSchemes.contains(scheme) {
            if let token = fragmentToken(from: components.percentEncodedFragment),
               let credential = usable(token) {
                return credential
            }
            if let token = queryToken(from: components.percentEncodedQuery),
               let credential = usable(token) {
                return credential
            }
            return nil
        }

        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return trimmed
    }

    private static func fragmentToken(from encodedFragment: String?) -> String? {
        guard var encodedFragment, !encodedFragment.isEmpty else { return nil }
        if encodedFragment.first == "?" { encodedFragment.removeFirst() }
        if encodedFragment == "token"
            || encodedFragment.hasPrefix("token=")
            || encodedFragment.contains("&token=") {
            return queryToken(from: encodedFragment)
        }
        return nil
    }

    private static func queryToken(from encodedQuery: String?) -> String? {
        guard let encodedQuery else { return nil }
        for item in encodedQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let encodedName = parts.first,
                  String(encodedName).removingPercentEncoding == "token" else { continue }
            return parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil
        }
        return nil
    }

    private static func usable(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import AppKit

/// Finds the best icon a site offers and returns it as a 128×128 PNG.
@MainActor
enum IconFetcher {
    static func fetchIcon(domain: String) async -> Data? {
        guard let base = URL(string: "https://\(domain)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await get(base), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            candidates += iconLinks(in: html, baseURL: response.url ?? base)
        }
        candidates += [base.appending(path: "apple-touch-icon.png"), base.appending(path: "favicon.ico")]

        for url in candidates {
            guard !Task.isCancelled else { return nil }
            if let (data, _) = try? await get(url), let png = normalized(data) {
                return png
            }
        }
        return nil
    }

    /// Icon URLs from `<link rel="…icon…">` tags, best first: apple-touch icons, then by declared size.
    static func iconLinks(in html: String, baseURL: URL) -> [URL] {
        let tagPattern = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
        let attributePattern = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*[\"']([^\"']*)[\"']")
        let range = NSRange(html.startIndex..., in: html)

        var scored: [(url: URL, score: Int)] = []
        for match in tagPattern.matches(in: html, range: range) {
            let tag = (html as NSString).substring(with: match.range)
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                let key = (tag as NSString).substring(with: attribute.range(at: 1)).lowercased()
                attributes[key] = (tag as NSString).substring(with: attribute.range(at: 2))
            }
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            else { continue }
            let size = attributes["sizes"]?
                .split(separator: " ")
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }
                .max() ?? 16
            let score = (rel.contains("apple-touch-icon") ? 1000 : 0) + min(size, 512)
            scored.append((url, score))
        }
        return scored.sorted { $0.score > $1.score }.map(\.url)
    }

    private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private static func normalized(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let side = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // Prefer the largest bitmap representation (e.g. from a multi-size .ico).
        let best = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        if let best { best.draw(in: rect) } else { image.draw(in: rect) }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

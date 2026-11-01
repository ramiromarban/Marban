import Foundation
@preconcurrency import UIKit
import ImageIO

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, UIImage>()
    private var flights: [String: Task<UIImage?, Never>] = [:]
    private var failed: [String: Date] = [:]
    private let index: [String: [String: String]]
    private let session: URLSession

    init() {
        let bytes = AssetFiles.data("poster-index.json") ?? Data()
        index = (try? JSONDecoder().decode([String: [String: String]].self, from: bytes)) ?? [:]
        memory.totalCostLimit = 24 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, diskPath: "GuizadoArtwork")
        session = URLSession(configuration: configuration)
    }
    func bundled(_ media: Media) -> UIImage? {
        guard let path = index["byId"]?[media.artworkKey] ?? index["byUrl"]?[media.image], let url = AssetFiles.url(path) else { return nil }
        if let cached = memory.object(forKey: path as NSString) { return cached }
        guard let bytes = try? Data(contentsOf: url), let image = Self.decode(bytes) else { return nil }
        remember(image, key: path); return image
    }
    func image(_ address: String, referer: String = "") async -> UIImage? {
        guard !address.isEmpty, let url = URL(string: address), ["https", "http"].contains(url.scheme ?? "") else { return nil }
        if let cached = memory.object(forKey: address as NSString) { return cached }
        if let date = failed[address], Date().timeIntervalSince(date) < 120 { return nil }
        if let existing = flights[address] { return await existing.value }
        let session = self.session
        let request = Task<UIImage?, Never> {
            var request = URLRequest(url: url); request.setValue(CatalogService.userAgent, forHTTPHeaderField: "User-Agent")
            if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
            guard let (bytes, response) = try? await session.data(for: request), let response = response as? HTTPURLResponse,
                  response.statusCode == 200, bytes.count < 5_000_000 else { return nil }
            return Self.decode(bytes)
        }
        flights[address] = request
        let result = await request.value; flights.removeValue(forKey: address)
        if let result { remember(result, key: address) } else { failed[address] = Date() }
        return result
    }
    private func remember(_ image: UIImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 960,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

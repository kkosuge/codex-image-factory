import CoreGraphics
import Foundation
import ImageIO

/// 生成画像のサムネイル。メインスレッド外で縮小して読み、少しだけ覚えておく。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    static let maxPixelSize = 480
    private static let cacheLimit = 120

    private var cache: [String: CGImage] = [:]
    private var order: [String] = []

    func thumbnail(for path: String) async -> CGImage? {
        if let hit = cache[path] {
            return hit
        }
        let size = Self.maxPixelSize
        let image = await Task.detached(priority: .utility) {
            ThumbnailLoader.makeThumbnail(path: path, maxPixelSize: size)
        }.value
        if let image {
            store(image, for: path)
        }
        return image
    }

    private func store(_ image: CGImage, for path: String) {
        if cache[path] == nil {
            order.append(path)
        }
        cache[path] = image
        while order.count > Self.cacheLimit {
            cache[order.removeFirst()] = nil
        }
    }

    /// ImageIO で縮小して読む（元の大きさのまま読み込まない）。
    nonisolated static func makeThumbnail(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

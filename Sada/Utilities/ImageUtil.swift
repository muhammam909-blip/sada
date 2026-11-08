import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ImageUtil {
    /// Decodes and downsamples an image file without loading the full bitmap.
    nonisolated static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    nonisolated static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    nonisolated private static func thumbnail(_ source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel)),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Normalises any artwork data to a JPEG no larger than `maxPixel`.
    nonisolated static func normalizedJPEG(_ data: Data, maxPixel: CGFloat = 1200, quality: CGFloat = 0.88) -> Data? {
        guard let image = downsample(data: data, maxPixel: maxPixel) else { return nil }
        return image.jpegData(compressionQuality: quality)
    }
}

/// Small in-memory cache for list thumbnails.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 400 }

    func image(for trackID: String, pixelSize: CGFloat) async -> UIImage? {
        let key = "\(trackID)-\(Int(pixelSize))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = LibraryStore.shared.artworkFileURL(trackID)
        let image = await Task.detached(priority: .userInitiated) {
            ImageUtil.downsample(url: url, maxPixel: pixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Downloads (and caches) artwork for streamed songs.
    func remoteImage(url: URL, pixelSize: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)-\(Int(pixelSize))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard case let (data, 200)? = await HTTP.get(url) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            ImageUtil.downsample(data: data, maxPixel: pixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func invalidate(_ trackID: String) {
        // NSCache can't enumerate; sizes used in the app are few, so remove the common ones.
        for size in [80, 120, 132, 200, 300, 360, 400, 480, 600, 800, 1000, 1200] {
            cache.removeObject(forKey: "\(trackID)-\(size)" as NSString)
        }
    }
}

enum ColorExtractor {
    static let fallback: [Color] = [
        Color(red: 0.35, green: 0.12, blue: 0.25), Color(red: 0.22, green: 0.10, blue: 0.30), Color(red: 0.12, green: 0.10, blue: 0.25),
        Color(red: 0.45, green: 0.15, blue: 0.30), Color(red: 0.30, green: 0.12, blue: 0.35), Color(red: 0.15, green: 0.12, blue: 0.30),
        Color(red: 0.25, green: 0.08, blue: 0.20), Color(red: 0.18, green: 0.08, blue: 0.24), Color(red: 0.08, green: 0.08, blue: 0.18),
    ]

    /// 3×3 grid of colours sampled from the artwork, darkened for white text on top.
    static func palette(from image: UIImage?) -> [Color] {
        guard let cg = image?.cgImage else { return fallback }
        let w = 3, h = 3
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return fallback }

        var colors: [Color] = []
        for i in 0..<(w * h) {
            let r = CGFloat(pixels[i * 4]) / 255, g = CGFloat(pixels[i * 4 + 1]) / 255, b = CGFloat(pixels[i * 4 + 2]) / 255
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            let adjusted = UIColor(hue: hue, saturation: min(sat * 1.15, 1), brightness: min(bri, 0.62) * 0.85, alpha: 1)
            colors.append(Color(uiColor: adjusted))
        }
        return colors
    }
}

import Foundation
import ImageIO
import CoreGraphics

public struct ModelImageAttachment: Codable, Sendable, Equatable {
    public let title: String
    public let mimeType: String
    public let base64Data: String

    public init(title: String, mimeType: String, base64Data: String) {
        self.title = title
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    public var dataURI: String { "data:\(mimeType);base64,\(base64Data)" }
}

public enum ModelImageAttachmentLoader {
    public static let minimumPixelCount = 512
    public static let maxEncodedBytes = 4 * 1024 * 1024

    public enum LoaderError: Error, LocalizedError {
        case unreadable(String)
        case tooLarge(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let message): return message
            case .tooLarge(let message): return message
            }
        }
    }

    public static func load(from url: URL, title: String) throws -> ModelImageAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoaderError.unreadable("Could not read image at \(url.path).")
        }

        let mimeType = mimeType(for: url, source: source)
        let prepared = ensureMinimumPixels(image, minimumPixelCount: minimumPixelCount)
        let data = try encode(prepared, mimeType: mimeType)
        guard data.count <= maxEncodedBytes else {
            throw LoaderError.tooLarge("Image \(title) exceeds the \(maxEncodedBytes) byte vision limit.")
        }
        return ModelImageAttachment(
            title: title,
            mimeType: mimeType,
            base64Data: data.base64EncodedString()
        )
    }

    public static func loadAll(from urls: [(url: URL, title: String)]) throws -> [ModelImageAttachment] {
        try urls.map { try load(from: $0.url, title: $0.title) }
    }

    private static func mimeType(for url: URL, source: CGImageSource) -> String {
        if let type = CGImageSourceGetType(source) as String? {
            switch type.lowercased() {
            case "public.jpeg", "image/jpeg": return "image/jpeg"
            case "public.png", "image/png": return "image/png"
            case "public.heic", "image/heic": return "image/heic"
            case "public.heif", "image/heif": return "image/heif"
            case "public.webp", "image/webp": return "image/webp"
            case "com.compuserve.gif", "image/gif": return "image/gif"
            default: break
            }
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    private static func ensureMinimumPixels(_ image: CGImage, minimumPixelCount: Int) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }
        let pixelCount = width * height
        guard pixelCount < minimumPixelCount else { return image }

        let scale = sqrt(Double(minimumPixelCount) / Double(pixelCount))
        let targetWidth = max(Int(ceil(Double(width) * scale)), 1)
        let targetHeight = max(Int(ceil(Double(height) * scale)), 1)

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private static func encode(_ image: CGImage, mimeType: String) throws -> Data {
        let data = NSMutableData()
        let type: CFString
        switch mimeType {
        case "image/jpeg": type = "public.jpeg" as CFString
        case "image/png": type = "public.png" as CFString
        case "image/heic": type = "public.heic" as CFString
        case "image/heif": type = "public.heif" as CFString
        case "image/webp": type = "public.webp" as CFString
        case "image/gif": type = "com.compuserve.gif" as CFString
        default: type = "public.png" as CFString
        }
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw LoaderError.unreadable("Could not encode image.")
        }
        let properties: [CFString: Any]
        if mimeType == "image/jpeg" {
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92]
        } else {
            properties = [:]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LoaderError.unreadable("Could not finalize encoded image.")
        }
        return data as Data
    }
}
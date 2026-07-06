import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OntologyKit

@Test func modelImageAttachmentLoaderUpscalesTinyImages() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vision-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("tiny.png")
    try writeSolidPNG(at: url, width: 10, height: 10, rgb: (255, 0, 0))

    let attachment = try ModelImageAttachmentLoader.load(from: url, title: "tiny.png")
    #expect(attachment.mimeType == "image/png")
    #expect(!attachment.base64Data.isEmpty)
    #expect(attachment.dataURI.hasPrefix("data:image/png;base64,"))
}

@Test func grokSessionClientBuildsVisionPayload() {
    let image = ModelImageAttachment(title: "shot.png", mimeType: "image/png", base64Data: "abc123")
    let payload = GrokSessionClient.payloadMessage(
        for: GrokSessionClient.Message(role: "user", text: "What is this?", images: [image])
    )
    #expect(payload["role"] as? String == "user")
    let content = payload["content"] as? [[String: Any]]
    #expect(content?.count == 2)
    #expect(content?.first?["type"] as? String == "text")
    #expect(content?.last?["type"] as? String == "image_url")
}

@Test func codexSessionClientBuildsVisionPayload() {
    let image = ModelImageAttachment(title: "shot.png", mimeType: "image/png", base64Data: "abc123")
    let payload = CodexSessionClient.payloadMessage(
        for: CodexSessionClient.Message(role: "user", text: "What is this?", images: [image])
    )
    #expect(payload["role"] as? String == "user")
    let content = payload["content"] as? [[String: Any]]
    #expect(content?.count == 2)
    #expect(content?.first?["type"] as? String == "input_text")
    #expect(content?.last?["type"] as? String == "input_image")
}

private func writeSolidPNG(at url: URL, width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = rgb.0
        pixels[index + 1] = rgb.1
        pixels[index + 2] = rgb.2
        pixels[index + 3] = 255
    }
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw NSError(domain: "ModelImageAttachmentTests", code: 1)
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "ModelImageAttachmentTests", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ModelImageAttachmentTests", code: 3)
    }
}
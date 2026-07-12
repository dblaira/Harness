import CryptoKit
import Foundation
import Testing

@testable import OntologyKit

@Suite(.serialized)
struct UnderstoodHarnessBridgeTests {
  @Test func configurationRequiresSafeURLAndToken() {
    #expect(UnderstoodHarnessBridgeConfiguration(environment: [:]) == nil)
    #expect(
      UnderstoodHarnessBridgeConfiguration(environment: [
        "UNDERSTOOD_HARNESS_BRIDGE_URL": "http://example.com/api/harness/captures",
        "HARNESS_BRIDGE_TOKEN": "secret",
      ]) == nil)
    #expect(
      UnderstoodHarnessBridgeConfiguration(environment: [
        "UNDERSTOOD_HARNESS_BRIDGE_URL": "https://understood.app/api/harness/captures",
        "HARNESS_BRIDGE_TOKEN": "secret",
      ]) != nil)
    #expect(
      UnderstoodHarnessBridgeConfiguration(environment: [
        "UNDERSTOOD_HARNESS_BRIDGE_URL": "http://127.0.0.1:3000/api/harness/captures",
        "HARNESS_BRIDGE_TOKEN": "secret",
      ]) != nil)
  }

  @Test func clientBindsAcknowledgementToFetchedCaptureBytes() async throws {
    let protocolType = UnderstoodCaptureURLProtocol.self
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolType]
    let session = URLSession(configuration: configuration)
    let endpoint = URL(string: "https://understood.test/api/harness/captures")!
    let capture = understoodBridgeCapture()
    let captureObject = try #require(
      JSONSerialization.jsonObject(with: capture) as? [String: Any]
    )
    let rawSHA256 = understoodSHA256(capture)
    protocolType.handler = { request in
      if request.httpMethod == "GET" {
        let data = try JSONSerialization.data(withJSONObject: [
          "status": "pending",
          "capture": captureObject,
          "capture_json": String(decoding: capture, as: UTF8.self),
          "capture_sha256": rawSHA256,
        ])
        return (
          HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          data
        )
      }
      let body = try #require(understoodRequestBody(request))
      let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(object["capture_id"] as? String == "capture-understood-entry-1")
      #expect(object["capture_sha256"] as? String == rawSHA256)
      let data = try JSONSerialization.data(withJSONObject: [
        "status": "acknowledged",
        "capture_id": "capture-understood-entry-1",
        "capture_sha256": rawSHA256,
      ])
      return (
        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!, data
      )
    }
    defer { protocolType.handler = nil }
    let client = UnderstoodHarnessBridgeClient(endpoint: endpoint, token: "token", session: session)

    #expect(
      try await client.fetchCapture()
        == UnderstoodHarnessBridgeFetchedCapture(
          data: capture,
          rawSHA256: rawSHA256
        ))
    #expect(
      try await client.acknowledge(
        captureID: "capture-understood-entry-1",
        rawSHA256: rawSHA256
      ) == .acknowledged)
  }

  @Test func clientRejectsCaptureWhoseAdvertisedDigestDoesNotMatchItsBytes() async throws {
    let protocolType = UnderstoodCaptureURLProtocol.self
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolType]
    let session = URLSession(configuration: configuration)
    let endpoint = URL(string: "https://understood.test/api/harness/captures")!
    let capture = understoodBridgeCapture()
    let captureObject = try #require(
      JSONSerialization.jsonObject(with: capture) as? [String: Any]
    )
    protocolType.handler = { _ in
      let data = try JSONSerialization.data(withJSONObject: [
        "status": "pending",
        "capture": captureObject,
        "capture_json": String(decoding: capture, as: UTF8.self),
        "capture_sha256": String(repeating: "0", count: 64),
      ])
      return (
        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!, data
      )
    }
    defer { protocolType.handler = nil }
    let client = UnderstoodHarnessBridgeClient(endpoint: endpoint, token: "token", session: session)

    do {
      _ = try await client.fetchCapture()
      Issue.record("Expected mismatched capture bytes to be rejected")
    } catch let error as UnderstoodHarnessBridgeError {
      #expect(error == .contentDigestMismatch)
    }
  }

  @Test func pollerRetainsFetchedBytesButDoesNotAcknowledgeAfterServerDetectsMutation() async throws
  {
    let protocolType = UnderstoodCaptureURLProtocol.self
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolType]
    let session = URLSession(configuration: configuration)
    let endpoint = URL(string: "https://understood.test/api/harness/captures")!
    let capture = understoodBridgeCapture()
    let captureObject = try #require(
      JSONSerialization.jsonObject(with: capture) as? [String: Any]
    )
    let rawSHA256 = understoodSHA256(capture)
    protocolType.handler = { request in
      if request.httpMethod == "GET" {
        let data = try JSONSerialization.data(withJSONObject: [
          "status": "pending",
          "capture": captureObject,
          "capture_json": String(decoding: capture, as: UTF8.self),
          "capture_sha256": rawSHA256,
        ])
        return (
          HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          data
        )
      }
      let body = try #require(understoodRequestBody(request))
      let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(object["capture_id"] as? String == "capture-understood-entry-1")
      #expect(object["capture_sha256"] as? String == rawSHA256)
      let data = try JSONSerialization.data(withJSONObject: [
        "error": "Capture content changed before acknowledgement"
      ])
      return (
        HTTPURLResponse(url: endpoint, statusCode: 409, httpVersion: nil, headerFields: nil)!, data
      )
    }
    defer { protocolType.handler = nil }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("understood-bridge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receiptStore = SuiteCaptureReceiptStore(root: root)
    let poller = UnderstoodHarnessBridgePoller(
      client: UnderstoodHarnessBridgeClient(endpoint: endpoint, token: "token", session: session),
      receiptStore: receiptStore
    )

    do {
      _ = try await poller.poll()
      Issue.record("Expected the content-bound acknowledgement to be rejected")
    } catch let error as UnderstoodHarnessBridgeError {
      #expect(error == .http(409))
    }
    let receipt = try #require(try await receiptStore.listReceipts().first)
    #expect(receipt.rawSHA256 == rawSHA256)
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.rawCapturePath)) == capture)
  }
}

private func understoodRequestBody(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 1_024)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count >= 0 else { return nil }
    if count == 0 { break }
    data.append(buffer, count: count)
  }
  return data
}

private func understoodBridgeCapture() -> Data {
  try! JSONSerialization.data(
    withJSONObject: [
      "schema_version": "suite_capture.v1",
      "capture_id": "capture-understood-entry-1",
      "captured_at": "2026-07-11T20:00:00Z",
      "capture_kind": "entry.created",
      "source_app": "understood",
      "source_record_id": "entry-1",
      "payload": ["content": "raw entry"],
      "artifact_refs": [],
    ], options: [.sortedKeys, .withoutEscapingSlashes])
}

private func understoodSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class UnderstoodCaptureURLProtocol: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (response, data) = try Self.handler!(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

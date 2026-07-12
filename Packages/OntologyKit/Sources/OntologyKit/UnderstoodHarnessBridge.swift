import CryptoKit
import Foundation

public struct UnderstoodHarnessBridgeConfiguration: Sendable, Equatable {
  public let endpoint: URL
  public let token: String

  public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard
      let rawURL = environment["UNDERSTOOD_HARNESS_BRIDGE_URL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let endpoint = URL(string: rawURL),
      Self.isAllowed(endpoint: endpoint),
      let token = environment["HARNESS_BRIDGE_TOKEN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { return nil }
    self.endpoint = endpoint
    self.token = token
  }

  private static func isAllowed(endpoint: URL) -> Bool {
    guard let scheme = endpoint.scheme?.lowercased(),
      let host = endpoint.host?.lowercased()
    else { return false }
    return scheme == "https"
      || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
  }
}

public enum UnderstoodHarnessBridgeError: Error, LocalizedError, Sendable, Equatable {
  case http(Int)
  case invalidResponse
  case contentDigestMismatch

  public var errorDescription: String? {
    switch self {
    case .http(let status):
      return "Understood capture bridge returned HTTP \(status)."
    case .invalidResponse:
      return "Understood capture bridge returned an invalid response."
    case .contentDigestMismatch:
      return "Understood capture bridge content changed or did not match its receipt identity."
    }
  }
}

public enum UnderstoodHarnessBridgeAcknowledgement: String, Sendable, Equatable {
  case acknowledged
  case alreadyAcknowledged = "already_acknowledged"
}

/// The exact canonical capture bytes offered by Understood, bound to the
/// SHA-256 identity that must be echoed when Harness acknowledges them.
public struct UnderstoodHarnessBridgeFetchedCapture: Sendable, Equatable {
  public let data: Data
  public let rawSHA256: String

  public init(data: Data, rawSHA256: String) {
    self.data = data
    self.rawSHA256 = rawSHA256
  }
}

public struct UnderstoodHarnessBridgeClient: @unchecked Sendable {
  private let endpoint: URL
  private let token: String
  private let session: URLSession

  public init(endpoint: URL, token: String, session: URLSession = .shared) {
    self.endpoint = endpoint
    self.token = token
    self.session = session
  }

  public init(
    configuration: UnderstoodHarnessBridgeConfiguration,
    session: URLSession = .shared
  ) {
    self.init(endpoint: configuration.endpoint, token: configuration.token, session: session)
  }

  public func fetchCapture() async throws -> UnderstoodHarnessBridgeFetchedCapture? {
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    try Self.requireSuccess(response)

    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = object["status"] as? String
    else {
      throw UnderstoodHarnessBridgeError.invalidResponse
    }
    switch status {
    case "empty":
      guard object["capture"] == nil || object["capture"] is NSNull,
        object["capture_json"] == nil,
        object["capture_sha256"] == nil
      else {
        throw UnderstoodHarnessBridgeError.invalidResponse
      }
      return nil
    case "pending":
      guard let capture = object["capture"] as? [String: Any],
        JSONSerialization.isValidJSONObject(capture),
        let captureJSON = object["capture_json"] as? String,
        let captureData = captureJSON.data(using: .utf8),
        let rawCapture = try? JSONSerialization.jsonObject(with: captureData) as? [String: Any],
        JSONSerialization.isValidJSONObject(rawCapture),
        let rawSHA256 = object["capture_sha256"] as? String,
        Self.isLowercaseSHA256(rawSHA256)
      else {
        throw UnderstoodHarnessBridgeError.invalidResponse
      }
      let advertisedCaptureData = try JSONSerialization.data(
        withJSONObject: capture,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      let rawCaptureData = try JSONSerialization.data(
        withJSONObject: rawCapture,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      guard advertisedCaptureData == rawCaptureData else {
        throw UnderstoodHarnessBridgeError.invalidResponse
      }
      guard Self.sha256Hex(captureData) == rawSHA256 else {
        throw UnderstoodHarnessBridgeError.contentDigestMismatch
      }
      return UnderstoodHarnessBridgeFetchedCapture(
        data: captureData,
        rawSHA256: rawSHA256
      )
    default:
      throw UnderstoodHarnessBridgeError.invalidResponse
    }
  }

  public func acknowledge(
    captureID: String,
    rawSHA256: String
  ) async throws -> UnderstoodHarnessBridgeAcknowledgement {
    guard Self.isLowercaseSHA256(rawSHA256) else {
      throw UnderstoodHarnessBridgeError.invalidResponse
    }
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: [
        "capture_id": captureID,
        "capture_sha256": rawSHA256,
      ],
      options: [.sortedKeys]
    )
    let (data, response) = try await session.data(for: request)
    try Self.requireSuccess(response)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawStatus = object["status"] as? String,
      let status = UnderstoodHarnessBridgeAcknowledgement(rawValue: rawStatus),
      object["capture_id"] as? String == captureID,
      object["capture_sha256"] as? String == rawSHA256
    else {
      throw UnderstoodHarnessBridgeError.invalidResponse
    }
    return status
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }

  private static func requireSuccess(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw UnderstoodHarnessBridgeError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw UnderstoodHarnessBridgeError.http(http.statusCode)
    }
  }
}

public enum UnderstoodHarnessBridgePollResult: Sendable, Equatable {
  case empty
  case storedAndAcknowledged(String)
  case duplicateAndAcknowledged(String)
  case conflictPreservedAndAcknowledged(String)
}

/// Remote acknowledgement means only that Harness durably retained the raw
/// capture. It is deliberately independent of analysis, review, and accepted
/// graph promotion.
public struct UnderstoodHarnessBridgePoller: Sendable {
  private let client: UnderstoodHarnessBridgeClient
  private let receiptStore: SuiteCaptureReceiptStore
  private let trustedSource: TrustedSuiteCaptureSource

  public init(
    client: UnderstoodHarnessBridgeClient,
    receiptStore: SuiteCaptureReceiptStore,
    trustedSource: TrustedSuiteCaptureSource = .init(id: "understood", displayName: "Understood")
  ) {
    self.client = client
    self.receiptStore = receiptStore
    self.trustedSource = trustedSource
  }

  public func poll() async throws -> UnderstoodHarnessBridgePollResult {
    guard let fetched = try await client.fetchCapture() else { return .empty }
    let disposition = try await receiptStore.ingest(data: fetched.data, from: trustedSource)
    let captureID = disposition.receipt.capture.captureID
    guard disposition.receipt.rawSHA256 == fetched.rawSHA256 else {
      throw UnderstoodHarnessBridgeError.contentDigestMismatch
    }
    _ = try await client.acknowledge(
      captureID: captureID,
      rawSHA256: disposition.receipt.rawSHA256
    )
    switch disposition {
    case .stored:
      return .storedAndAcknowledged(captureID)
    case .duplicate:
      return .duplicateAndAcknowledged(captureID)
    case .conflict:
      return .conflictPreservedAndAcknowledged(captureID)
    }
  }
}

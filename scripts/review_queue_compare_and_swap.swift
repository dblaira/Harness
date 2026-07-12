#!/usr/bin/env swift

import Darwin
import Foundation

guard CommandLine.arguments.count == 4 else {
  FileHandle.standardError.write(Data("usage: review_queue_compare_and_swap.swift QUEUE EXPECTED REPLACEMENT\n".utf8))
  exit(64)
}

let queueURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedURL = URL(fileURLWithPath: CommandLine.arguments[2])
let replacementURL = URL(fileURLWithPath: CommandLine.arguments[3])

do {
  let expected = try Data(contentsOf: expectedURL)
  let replacement = try Data(contentsOf: replacementURL)
  let coordinator = NSFileCoordinator(filePresenter: nil)
  var coordinationError: NSError?
  var accessorError: Error?
  var matched = false

  coordinator.coordinate(
    writingItemAt: queueURL,
    options: .forReplacing,
    error: &coordinationError
  ) { coordinatedURL in
    do {
      guard try Data(contentsOf: coordinatedURL) == expected else { return }
      try replacement.write(to: coordinatedURL, options: .atomic)
      matched = true
    } catch {
      accessorError = error
    }
  }

  if let coordinationError { throw coordinationError }
  if let accessorError { throw accessorError }
  exit(matched ? 0 : 2)
} catch {
  FileHandle.standardError.write(Data("review queue coordination failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}

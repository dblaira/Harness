import Foundation

/// Shared file coordination for every read/replace transaction against the
/// canonical review queue. Atomic writes prevent partial JSON; coordination
/// prevents a writer from replacing a newer local or iCloud-visible snapshot.
enum ReviewQueueFileCoordinator {
    static func read(queueURL: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorResult: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: queueURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            accessorResult = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let accessorResult else {
            throw CocoaError(.fileReadUnknown)
        }
        return try accessorResult.get()
    }

    static func mutate<ResultValue>(
        queueURL: URL,
        _ mutation: (Data) throws -> (replacement: Data?, result: ResultValue)
    ) throws -> ResultValue {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorResult: Result<ResultValue, Error>?
        coordinator.coordinate(
            writingItemAt: queueURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            accessorResult = Result {
                let current = try Data(contentsOf: coordinatedURL)
                let mutationResult = try mutation(current)
                if let replacement = mutationResult.replacement {
                    try replacement.write(to: coordinatedURL, options: .atomic)
                }
                return mutationResult.result
            }
        }
        if let coordinationError { throw coordinationError }
        guard let accessorResult else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try accessorResult.get()
    }

    static func compareAndSwap(
        queueURL: URL,
        expected: Data,
        replacement: Data
    ) throws -> Bool {
        try mutate(queueURL: queueURL) { current in
            guard current == expected else {
                return (replacement: nil, result: false)
            }
            return (replacement: replacement, result: true)
        }
    }
}

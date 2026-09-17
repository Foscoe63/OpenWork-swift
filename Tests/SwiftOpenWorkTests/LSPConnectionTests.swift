import XCTest
@testable import SwiftOpenWork

/// The wire protocol, over pipes with no process behind them, so each way a server can misbehave
/// is produced on purpose. The property under test throughout: a waiting request always ends.
final class LSPConnectionTests: XCTestCase {

    /// A fake server: what the client writes arrives in `fromClient`, and `send` plays the server.
    private final class Wire: @unchecked Sendable {
        let toServer = Pipe()
        let toClient = Pipe()
        private let lock = NSLock()
        private var received = Data()

        init() {
            toServer.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { return }
                self.lock.withLock { self.received.append(chunk) }
            }
        }

        func connect(
            onServerRequest: @escaping LSPConnection.ServerRequestHandler = { method, _ in .failure(.methodNotFound(method)) },
            onNotification: @escaping LSPConnection.NotificationHandler = { _, _ in }
        ) -> LSPConnection {
            LSPConnection(
                name: "fake-server",
                process: nil,
                toServer: toServer.fileHandleForWriting,
                fromServer: toClient.fileHandleForReading,
                onServerRequest: onServerRequest,
                onNotification: onNotification
            )
        }

        func send(raw: Data) {
            toClient.fileHandleForWriting.write(raw)
        }

        func send(_ object: [String: Any]) {
            send(raw: Self.frame(object))
        }

        static func frame(_ object: [String: Any]) -> Data {
            let body = try! JSONSerialization.data(withJSONObject: object)
            return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        }

        /// Messages the client has written so far, decoded.
        func messages() -> [[String: Any]] {
            var data = lock.withLock { received }
            var out: [[String: Any]] = []
            let separator = Data("\r\n\r\n".utf8)
            while let headerEnd = data.range(of: separator),
                  let length = LSPConnection.contentLength(inHeader: String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)),
                  data.distance(from: headerEnd.upperBound, to: data.endIndex) >= length {
                let end = data.index(headerEnd.upperBound, offsetBy: length)
                if let object = try? JSONSerialization.jsonObject(with: data[headerEnd.upperBound..<end]) as? [String: Any] {
                    out.append(object)
                }
                data = Data(data[end...])
            }
            return out
        }

        /// Wait until the client has written a message matching `predicate`.
        func waitForMessage(timeout: TimeInterval = 5, where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let match = messages().first(where: predicate) { return match }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("client never wrote the expected message; wrote \(messages())")
            throw CancellationError()
        }
    }

    func testAResponseSplitAcrossChunksAndTwoInOneChunkAreBothRead() async throws {
        let wire = Wire()
        let connection = wire.connect()
        async let first = connection.request("first", nil, timeout: 5)
        async let second = connection.request("second", nil, timeout: 5)
        let firstRequest = try await wire.waitForMessage { $0["method"] as? String == "first" }
        let secondRequest = try await wire.waitForMessage { $0["method"] as? String == "second" }

        let one = Wire.frame(["jsonrpc": "2.0", "id": firstRequest["id"]!, "result": "a"])
        let two = Wire.frame(["jsonrpc": "2.0", "id": secondRequest["id"]!, "result": "b"])
        // The first message arrives in two pieces, the second is glued onto the end of the first.
        wire.send(raw: one.prefix(7))
        try await Task.sleep(nanoseconds: 50_000_000)
        wire.send(raw: one.dropFirst(7) + two)

        let results = try await [first, second]
        XCTAssertEqual(results.map { $0 as? String }, ["a", "b"])
    }

    func testAnErrorResponseKeepsItsCodeSoMethodNotFoundCanBeRecognised() async throws {
        let wire = Wire()
        let connection = wire.connect()
        async let call = connection.request("workspace/unknown", nil, timeout: 5)
        let request = try await wire.waitForMessage { $0["method"] as? String == "workspace/unknown" }
        wire.send(["jsonrpc": "2.0", "id": request["id"]!, "error": ["code": -32601, "message": "method not found"]])
        do {
            _ = try await call
            XCTFail("an error response must throw")
        } catch let failure as LSPConnection.Failure {
            XCTAssertTrue(failure.isMethodNotFound)
        }
    }

    /// A server that asks us something and gets no answer may wait forever.
    func testServerRequestsAreAnswered() async throws {
        let wire = Wire()
        let connection = wire.connect(onServerRequest: { method, _ in
            method == "workspace/configuration" ? .success([NSNull()]) : .failure(.methodNotFound(method))
        })
        _ = connection
        wire.send(["jsonrpc": "2.0", "id": 90, "method": "workspace/configuration", "params": ["items": [[:] as [String: Any]]]])
        wire.send(["jsonrpc": "2.0", "id": "text-id", "method": "something/unknown"])

        let answer = try await wire.waitForMessage { ($0["id"] as? Int) == 90 }
        XCTAssertEqual((answer["result"] as? [Any])?.count, 1)
        let refusal = try await wire.waitForMessage { ($0["id"] as? String) == "text-id" }
        XCTAssertEqual((refusal["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    /// Once the stream is out of step every later message would be misread, so the connection
    /// fails — and a request already waiting learns that now rather than at its timeout.
    func testAMalformedHeaderFailsWaitingRequestsImmediately() async throws {
        let wire = Wire()
        let connection = wire.connect()
        let started = Date()
        async let call = connection.request("slow", nil, timeout: 30)
        _ = try await wire.waitForMessage { $0["method"] as? String == "slow" }
        wire.send(raw: Data("Content-Type: nonsense\r\n\r\n{}".utf8))
        do {
            _ = try await call
            XCTFail("the request must fail")
        } catch let failure as LSPConnection.Failure {
            XCTAssertTrue(failure.localizedDescription.contains("Content-Length"), failure.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(connection.isAlive)
    }

    func testTheServerClosingItsOutputFailsWaitingRequests() async throws {
        let wire = Wire()
        let connection = wire.connect()
        async let call = connection.request("slow", nil, timeout: 30)
        _ = try await wire.waitForMessage { $0["method"] as? String == "slow" }
        try wire.toClient.fileHandleForWriting.close()
        do {
            _ = try await call
            XCTFail("the request must fail")
        } catch LSPConnection.Failure.unavailable {
            XCTAssertNotNil(connection.terminationReason)
        }
    }

    func testATimeoutEndsTheRequestAndTellsTheServerToStop() async throws {
        let wire = Wire()
        let connection = wire.connect()
        do {
            _ = try await connection.request("never", nil, timeout: 0.3)
            XCTFail("the request must time out")
        } catch LSPConnection.Failure.timedOut(let method, _) {
            XCTAssertEqual(method, "never")
        }
        _ = try await wire.waitForMessage { $0["method"] as? String == "$/cancelRequest" }
        XCTAssertTrue(connection.isAlive, "a slow answer is not a dead server")
    }

    /// Stopping a tool call must stop its wait, not leave it parked until the timeout.
    func testCancellingTheCallingTaskEndsTheRequest() async throws {
        let wire = Wire()
        let connection = wire.connect()
        let task = Task { try await connection.request("never", nil, timeout: 60) }
        _ = try await wire.waitForMessage { $0["method"] as? String == "never" }
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("the request must be cancelled")
        } catch LSPConnection.Failure.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
        _ = try await wire.waitForMessage { $0["method"] as? String == "$/cancelRequest" }
    }

    func testARequestOnADeadConnectionFailsAtOnce() async throws {
        let wire = Wire()
        let connection = wire.connect()
        connection.terminateNow()
        do {
            _ = try await connection.request("anything", nil, timeout: 30)
            XCTFail("a dead connection must refuse")
        } catch LSPConnection.Failure.unavailable {}
    }

    func testNotificationsReachTheHandler() async throws {
        let wire = Wire()
        let received = expectation(description: "notification")
        let connection = wire.connect(onNotification: { method, params in
            if method == "$/progress", params?["token"] as? String == "indexing" { received.fulfill() }
        })
        _ = connection
        wire.send(["jsonrpc": "2.0", "method": "$/progress", "params": ["token": "indexing", "value": ["kind": "begin"]]])
        await fulfillment(of: [received], timeout: 5)
    }

    func testContentLengthHeaderParsing() {
        XCTAssertEqual(LSPConnection.contentLength(inHeader: "Content-Length: 12"), 12)
        XCTAssertEqual(LSPConnection.contentLength(inHeader: "content-length:7\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8"), 7)
        XCTAssertEqual(LSPConnection.contentLength(inHeader: "Content-Type: x\r\nContent-Length: 3"), 3)
        XCTAssertNil(LSPConnection.contentLength(inHeader: "Content-Length: many"))
        XCTAssertNil(LSPConnection.contentLength(inHeader: "Content-Type: x"))
    }
}

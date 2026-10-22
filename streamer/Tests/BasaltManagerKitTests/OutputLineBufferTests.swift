import XCTest
@testable import BasaltManagerKit

final class OutputLineBufferTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testJoinsALineSplitAcrossChunks() {
        let buffer = OutputLineBuffer(prefix: "game: ")
        XCTAssertEqual(buffer.append(data("Basalt OpenXR [pi")), [])
        XCTAssertEqual(buffer.append(data("d 32]: head pose ")), [])
        XCTAssertEqual(buffer.append(data("pinning\n")),
                       ["game: Basalt OpenXR [pid 32]: head pose pinning"])
        XCTAssertNil(buffer.flush())
    }

    func testSplitsSeveralLinesInOneChunk() {
        let buffer = OutputLineBuffer(prefix: "wine: ")
        XCTAssertEqual(buffer.append(data("one\ntwo\n\nthree")),
                       ["wine: one", "wine: two", "wine: "])
        XCTAssertEqual(buffer.append(data(" end\n")), ["wine: three end"])
    }

    func testRemovesCRLFButKeepsInnerCarriageReturns() {
        let buffer = OutputLineBuffer(prefix: "")
        XCTAssertEqual(buffer.append(data("a\r\nb\rc\r")), ["a"])
        XCTAssertEqual(buffer.append(data("\nd\r\n")), ["b\rc", "d"])
    }

    func testDecodesAMultibyteCharacterSplitAcrossChunks() {
        let bytes = Array("caf\u{E9} \u{1F600}\n".utf8)
        let buffer = OutputLineBuffer(prefix: "> ")
        var lines = [String]()
        // One byte at a time cuts every multibyte character.
        for byte in bytes { lines += buffer.append(Data([byte])) }
        XCTAssertEqual(lines, ["> caf\u{E9} \u{1F600}"])
    }

    func testFlushesThePartialLastLineAtEndOfOutput() {
        let buffer = OutputLineBuffer(prefix: "steam: ")
        XCTAssertEqual(buffer.append(data("done\nlast words\r")), ["steam: done"])
        XCTAssertEqual(buffer.flush(), "steam: last words")
        XCTAssertNil(buffer.flush())
    }

    func testEmptyChunksChangeNothing() {
        let buffer = OutputLineBuffer(prefix: "p: ")
        XCTAssertEqual(buffer.append(Data()), [])
        XCTAssertNil(buffer.flush())
        XCTAssertEqual(buffer.append(data("ab")), [])
        XCTAssertEqual(buffer.append(Data()), [])
        XCTAssertEqual(buffer.append(data("c\n")), ["p: abc"])
    }

    func testPipesKeepSeparateBuffers() {
        let out = OutputLineBuffer(prefix: "game: ")
        let err = OutputLineBuffer(prefix: "game: ")
        XCTAssertEqual(out.append(data("head pose pin")), [])
        XCTAssertEqual(err.append(data("warning: x\n")), ["game: warning: x"])
        XCTAssertEqual(out.append(data("ning\n")), ["game: head pose pinning"])
    }
}

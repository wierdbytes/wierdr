import Foundation
import Testing
@testable import HerdrCore

@Suite struct FrameTests {
    let frames: [Frame] = [
        Frame(channel: 0, kind: .data, payload: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)),
        Frame(channel: 7, kind: .data, payload: Data((0..<5000).map { UInt8($0 % 251) })),
        .credit(7, 65536),
        Frame(channel: 7, kind: .close),
        .resize(3, cols: 120, rows: 40),
        Frame(channel: 0xFFFF_FFFF, kind: FrameKind(rawValue: 99), payload: Data([1, 2, 3])),
    ]

    var wire: Data { frames.reduce(into: Data()) { $0.append($1.encoded()) } }

    @Test func headerLayout() {
        let bytes = [UInt8](Frame(channel: 0x0102_0304, kind: .resize, payload: Data([9, 8])).encoded())
        #expect(bytes == [0x04, 0x03, 0x02, 0x01, 3, 2, 0, 0, 0, 9, 8])
    }

    @Test func decodesWholeStream() throws {
        var d = FrameDecoder()
        #expect(try d.push(wire) == frames)
        #expect(d.bufferedCount == 0)
    }

    @Test func decodesByteByByte() throws {
        var d = FrameDecoder()
        var out: [Frame] = []
        for b in wire { out += try d.push(Data([b])) }
        #expect(out == frames)
    }

    @Test func decodesArbitrarySplits() throws {
        var rng = SystemRandomNumberGenerator()
        let wire = wire
        for _ in 0..<200 {
            var d = FrameDecoder()
            var out: [Frame] = []
            var at = 0
            while at < wire.count {
                let n = Int.random(in: 1...700, using: &rng)
                let end = min(at + n, wire.count)
                out += try d.push(wire.subdata(in: at..<end))
                at = end
            }
            #expect(out == frames)
        }
    }

    @Test func rejectsOversizedFrames() {
        var header = Data()
        header.appendLE(UInt32(1))
        header.append(0)
        header.appendLE(UInt32(Frame.maxPayload + 1))
        var d = FrameDecoder()
        #expect(throws: FrameError.self) { try d.push(header) }
    }

    @Test func acceptsMaxPayload() throws {
        let f = Frame(channel: 2, kind: .data, payload: Data(count: Frame.maxPayload))
        var d = FrameDecoder()
        let wire = f.encoded()
        var out = try d.push(wire.prefix(100))
        out += try d.push(wire.dropFirst(100))
        #expect(out.count == 1 && out[0].payload.count == Frame.maxPayload)
    }

    @Test func controlPayloads() {
        #expect(Frame.resize(1, cols: 300, rows: 2).resizeSize! == (300, 2))
        #expect(Frame.credit(1, 0xDEAD_BEEF).creditBytes == 0xDEAD_BEEF)
        #expect(FrameKind(rawValue: 6) == .automaticInput)
    }

    @Test func inboundParserSwitchesAfterFirstLine() throws {
        var p = InboundParser()
        var bytes = Data(#"{"id":0}"#.utf8)
        bytes.append(0x0A)
        bytes.append(Frame(channel: 0, kind: .data, payload: Data("x".utf8)).encoded())
        var items: [InboundParser.Item] = []
        for b in bytes { items += try p.push(Data([b])) }
        #expect(items.count == 2)
        if case .line(let l) = items[0] { #expect(String(decoding: l, as: UTF8.self) == #"{"id":0}"#) } else { Issue.record("no line") }
        if case .frame(let f) = items[1] { #expect(f.payload == Data("x".utf8)) } else { Issue.record("no frame") }
    }
}

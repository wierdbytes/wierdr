import Foundation
import Testing
@testable import HerdrCore

@Suite struct JSONValueTests {
    func roundTrip(_ text: String) throws -> String {
        try JSONValue(parsing: text).jsonString()
    }

    @Test func numbersKeepTheirKind() throws {
        let v = try JSONValue(parsing: #"[0,-1,4.0,0.9999997615814208,1794324144003,9223372036854775807,-9223372036854775808,18446744073709551615,1e-05,2.5e+300]"#)
        #expect(v[0] == .int(0))
        #expect(v[2] == .double(4.0))
        #expect(v[3] == .double(0.9999997615814208))
        #expect(v[4] == .int(1_794_324_144_003))
        #expect(v[5] == .int(Int64.max))
        #expect(v[6] == .int(Int64.min))
        #expect(v[7] == .uint(UInt64.max))
        #expect(v[8]?.double == 1e-05)
        #expect(v[7]?.uint64 == UInt64.max)
        #expect(v[7]?.int == nil)
        #expect(v[2]?.int == 4)
    }

    @Test func roundTripsFaithfully() throws {
        let cases = [
            #"{"z":1,"a":2,"m":{"y":[1,2.5,"x",null,true,false],"b":{}}}"#,
            #"[18446744073709551615,-9223372036854775808,4.0,0.9999997615814208,1e-05]"#,
            #"{"weight":0.9999997615814208,"size":{"weight":4.0}}"#,
            #""line\nbreak \"quoted\" back\\slash tab\t ctl\u0001 é 😀""#,
            #"[]"#, #"{}"#, #"null"#,
        ]
        for c in cases { #expect(try roundTrip(c) == c) }
    }

    @Test func preservesKeyOrderThroughEdits() throws {
        var doc = try JSONValue(parsing: #"{"spaces":[],"zeta":1,"alpha":{"k2":1,"k1":2},"mid":true}"#)
        doc["zeta"] = 2  // existing key keeps its place
        doc["alpha"]?["k0"] = "new"  // new nested key goes last
        doc["added"] = .null
        doc["mid"] = nil  // removal
        #expect(doc.jsonString() == #"{"spaces":[],"zeta":2,"alpha":{"k2":1,"k1":2,"k0":"new"},"added":null}"#)
        #expect(doc.object?.keys == ["spaces", "zeta", "alpha", "added"])
    }

    @Test func equalityIgnoresKeyOrder() throws {
        #expect(try JSONValue(parsing: #"{"a":1,"b":2}"#) == JSONValue(parsing: #"{"b":2,"a":1}"#))
        #expect(try JSONValue(parsing: "4") != JSONValue(parsing: "4.0"))
    }

    @Test func unicodeEscapes() throws {
        #expect(try JSONValue(parsing: #""\u00e9\ud83d\ude00\u0041""#) == .string("é😀A"))
        #expect(try JSONValue(parsing: #""\ud800x""#) == .string("\u{FFFD}x"))  // lone surrogate
    }

    @Test func rejectsInvalidJSON() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "tru", "\"\u{01}\"", "[1] x", "{'a':1}", "nan"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try JSONValue(parsing: bad) }
        }
    }

    @Test func rejectsDeepNesting() {
        let ok = String(repeating: "[", count: 120) + String(repeating: "]", count: 120)
        #expect((try? JSONValue(parsing: ok)) != nil)
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: deep) }
    }

    @Test func nonFiniteCannotBeWritten() {
        #expect(throws: JSONWriteError.self) { try JSONValue.double(.infinity).data() }
    }

    @Test func prettyPrintKeepsOrder() throws {
        let v = try JSONValue(parsing: #"{"b":[1,{"c":null}],"a":{}}"#)
        #expect(v.jsonString(pretty: true) == "{\n  \"b\": [\n    1,\n    {\n      \"c\": null\n    }\n  ],\n  \"a\": {}\n}")
    }

    @Test func codableThroughFoundation() throws {
        let v: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": .null, "big": .uint(UInt64.max)]
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == v)
    }

    @Test func decodesModelsAndKeepsNestedValues() throws {
        struct M: Decodable {
            let n: Int
            let u: UInt64
            let raw: JSONValue
            let list: [String]
            let opt: String?
        }
        let v = try JSONValue(parsing: #"{"n":3,"u":18446744073709551615,"raw":{"z":1,"a":4.0},"list":["x"],"opt":null}"#)
        let m = try v.decode(M.self)
        #expect(m.n == 3 && m.u == UInt64.max && m.list == ["x"] && m.opt == nil)
        #expect(m.raw.jsonString() == #"{"z":1,"a":4.0}"#)
        #expect(throws: DecodingError.self) { try JSONValue(parsing: #"{"n":"x"}"#).decode(M.self) }
    }
}

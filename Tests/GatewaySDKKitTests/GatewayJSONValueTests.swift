import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("GatewayJSONValue")
struct GatewayJSONValueTests {
  @Test("Any -> value -> Any -> value round trips through JSONSerialization output")
  func anyRoundTrip() throws {
    let json = #"{"a":[1,2.5,true,null,"x"],"b":{"c":"d"}}"#
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    let value = try GatewayJSONValue(any: object)
    let back = try GatewayJSONValue(any: value.anyValue)
    #expect(back == value)
    #expect(
      value == .object([
        "a": .array([.int(1), .double(2.5), .bool(true), .null, .string("x")]),
        "b": .object(["c": .string("d")])
      ])
    )
  }

  @Test("value -> jsonString -> parse round trips")
  func jsonStringRoundTrip() throws {
    let value = GatewayJSONValue.object([
      "z": .array([.int(-3), .double(1.5), .null]),
      "a": .string("hi \"there\"\n\t"),
      "m": .bool(false),
      "empty": .object([:]),
      "list": .array([])
    ])
    let text = try value.jsonString()
    #expect(try GatewayJSONValue.parse(text) == value)
  }

  @Test("NSNumber bool, int and double are discriminated on real JSONSerialization output")
  func numberDiscrimination() throws {
    let json = #"{"b":true,"f":false,"i":1,"d":1.5,"neg":-2}"#
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    let value = try GatewayJSONValue(any: object)
    guard case .object(let members) = value else {
      Issue.record("expected an object")
      return
    }
    #expect(members["b"] == .bool(true))
    #expect(members["f"] == .bool(false))
    #expect(members["i"] == .int(1))
    #expect(members["d"] == .double(1.5))
    #expect(members["neg"] == .int(-2))
  }

  @Test("Swift Bool and Int are not confused with each other")
  func nativeSwiftNumbers() throws {
    #expect(try GatewayJSONValue(any: true) == .bool(true))
    #expect(try GatewayJSONValue(any: 1) == .int(1))
    #expect(try GatewayJSONValue(any: 1.0) == .double(1.0))
    #expect(try GatewayJSONValue(any: NSNumber(value: true)) == .bool(true))
    #expect(try GatewayJSONValue(any: NSNumber(value: 1)) == .int(1))
    #expect(try GatewayJSONValue(any: NSNumber(value: 1.0 as Double)) == .double(1.0))
    // 2^53 + 1 must survive as an Int: a Double detour would round it to 2^53.
    #expect(try GatewayJSONValue(any: NSNumber(value: Int64(9_007_199_254_740_993))) == .int(9_007_199_254_740_993))
    #expect(try GatewayJSONValue(any: NSNumber(value: UInt64(UInt64(Int.max) + 1))) == .double(9_223_372_036_854_775_808.0))
  }

  @Test("init(any:) accepts a GatewayJSONValue and rejects anything else")
  func initAnyEdges() throws {
    #expect(try GatewayJSONValue(any: GatewayJSONValue.int(7)) == .int(7))
    #expect(try GatewayJSONValue(any: NSNull()) == .null)
    #expect(throws: GatewaySDKError.self) {
      _ = try GatewayJSONValue(any: Date())
    }
  }

  @Test("object keys serialize sorted regardless of insertion order")
  func sortedKeys() throws {
    let value = GatewayJSONValue.object(["b": .int(2), "a": .int(1), "C": .int(3)])
    #expect(try value.jsonString() == #"{"C":3,"a":1,"b":2}"#)
  }

  @Test("pretty output golden")
  func prettyGolden() throws {
    let value = GatewayJSONValue.object([
      "b": .array([.int(1), .object(["x": .null])]),
      "a": .string("v")
    ])
    let expected = """
      {
        "a": "v",
        "b": [
          1,
          {
            "x": null
          }
        ]
      }
      """
    #expect(try value.jsonString(pretty: true) == expected)
  }

  @Test("string escaping covers quotes, backslashes, C0 controls and raw non-ASCII")
  func escaping() throws {
    let value = GatewayJSONValue.string("a\"b\\c\nd\te\u{0001}f\u{7}g_\u{3042}")
    let text = try value.jsonString()
    #expect(text == #""a\"b\\c\nd\te\u0001f\u0007g_\#u{3042}""#)
    #expect(try GatewayJSONValue.parse(text) == value)
  }

  @Test("non-finite doubles are rejected instead of serializing as inf or nan")
  func nonFiniteDoubles() throws {
    for number in [Double.infinity, -.infinity, .nan] {
      #expect(throws: GatewaySDKError.self) {
        _ = try GatewayJSONValue.double(number).jsonString()
      }
      // Also when nested, so the recursive writer cannot leak one through.
      #expect(throws: GatewaySDKError.self) {
        _ = try GatewayJSONValue.object(["x": .double(number)]).jsonString()
      }
      #expect(throws: GatewaySDKError.self) {
        _ = try GatewayJSONValue.array([.int(1), .double(number)]).jsonString(pretty: true)
      }
    }
    // Finite doubles, including the extremes, still serialize.
    #expect(try GatewayJSONValue.double(0).jsonString() == "0.0")
    #expect(try GatewayJSONValue.double(.greatestFiniteMagnitude).jsonString().isEmpty == false)
  }

  @Test("parse rejects malformed JSON")
  func parseFailure() {
    #expect(throws: GatewaySDKError.self) {
      _ = try GatewayJSONValue.parse("{not json")
    }
  }

  @Test("parse accepts fragments")
  func parseFragments() throws {
    #expect(try GatewayJSONValue.parse("7") == .int(7))
    #expect(try GatewayJSONValue.parse("\"s\"") == .string("s"))
    #expect(try GatewayJSONValue.parse("null") == .null)
    #expect(try GatewayJSONValue.parse("true") == .bool(true))
  }

  @Test("Codable round trips through JSONEncoder and JSONDecoder")
  func codableRoundTrip() throws {
    let value = GatewayJSONValue.object([
      "n": .null,
      "b": .bool(true),
      "i": .int(4),
      "d": .double(0.25),
      "s": .string("t"),
      "a": .array([.int(1), .string("2")])
    ])
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: data) == value)
  }

  @Test("Hashable membership works")
  func hashableSanity() {
    let set: Set<GatewayJSONValue> = [.int(1), .string("1"), .bool(true), .int(1)]
    #expect(set.count == 3)
    #expect(set.contains(.string("1")))
  }

  @Test("kindName names each case")
  func kindNames() {
    #expect(GatewayJSONValue.null.kindName == "null")
    #expect(GatewayJSONValue.bool(true).kindName == "bool")
    #expect(GatewayJSONValue.int(1).kindName == "int")
    #expect(GatewayJSONValue.double(1).kindName == "double")
    #expect(GatewayJSONValue.string("").kindName == "string")
    #expect(GatewayJSONValue.array([]).kindName == "array")
    #expect(GatewayJSONValue.object([:]).kindName == "object")
  }

  @Test("every error case renders a one-line description")
  func errorDescriptions() {
    let cases: [GatewaySDKError] = [
      .unknownOperation(name: "a"),
      .unknownVariable(operation: "a", name: "b"),
      .missingRequiredVariable(operation: "a", name: "b"),
      .invalidSelectionPath(path: "a.b"),
      .commandOperationNeedsArgv(name: "a"),
      .graphQLOperationNeedsDocument(name: "a"),
      .invalidPattern("bad"),
      .variableTypeMismatch(name: "a", expected: "Int", actual: "string"),
      .unusedVariable(operation: "a", name: "b"),
      .undeclaredVariable(name: "b"),
      .malformedDocument("x"),
      .invalidTypeReference("["),
      .invalidJSON("x"),
      .invalidJSONValue("x")
    ]
    #expect(cases.count == 14)
    for error in cases {
      #expect(!error.description.isEmpty)
      #expect(!error.description.contains("\n"))
    }
  }
}

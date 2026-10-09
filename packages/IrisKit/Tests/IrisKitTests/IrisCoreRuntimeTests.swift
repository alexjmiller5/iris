import Testing

@testable import IrisKit

@MainActor
struct IrisCoreRuntimeTests {
  let properties = #"[{"col":"title","type":"text","required":1},{"col":"priority","type":"int"}]"#

  @Test func sharedValidatorRejectsInvalidDraft() throws {
    let runtime = try IrisCoreRuntime()
    let result = try runtime.validate(
      propertiesJSON: properties, afterJSON: #"{"title":"","priority":"high"}"#)
    #expect(result.map(\.rule) == ["required", "type"])
    #expect(result.map(\.col) == ["title", "priority"])
  }

  @Test func sharedValidatorAcceptsValidDraft() throws {
    let runtime = try IrisCoreRuntime()
    #expect(
      try runtime.validate(
        propertiesJSON: properties, afterJSON: #"{"title":"Sample note","priority":2}"#
      ).isEmpty)
  }

  @Test func previousRowReachesImmutableRule() throws {
    let runtime = try IrisCoreRuntime()
    let result = try runtime.validate(
      propertiesJSON: #"[{"col":"id","immutable":1}]"#,
      beforeJSON: #"{"id":"fixture-1"}"#, afterJSON: #"{"id":"fixture-2"}"#)
    #expect(result.map(\.rule) == ["immutable"])
  }

  @Test func inputIsDataNeverEvaluatedCode() throws {
    let runtime = try IrisCoreRuntime()
    #expect(
      try runtime.validate(
        propertiesJSON: properties,
        afterJSON: #"{"title":"'); throw new Error('injected'); //","priority":1}"#
      ).isEmpty)
    #expect(
      try runtime.validate(
        propertiesJSON: properties,
        afterJSON: #"{"title":"Sample note","priority":1}"#
      ).isEmpty)
  }

  @Test func malformedInputFailsClosed() throws {
    let runtime = try IrisCoreRuntime()
    for invalid in ["{", "[]", "null"] {
      #expect(throws: (any Error).self) {
        try runtime.validate(propertiesJSON: properties, afterJSON: invalid)
      }
    }
    #expect(throws: (any Error).self) {
      try runtime.validate(propertiesJSON: #"[{"col":7}]"#, afterJSON: "{}")
    }
    #expect(throws: (any Error).self) {
      try runtime.validate(propertiesJSON: properties, beforeJSON: "[]", afterJSON: "{}")
    }
  }

  @Test func brokenBundleFailsClosed() {
    for script in ["throw new Error('broken bundle')", "globalThis.IrisCore = {}"] {
      #expect(throws: (any Error).self) { try IrisCoreRuntime(script: script) }
    }
  }

  @Test func javaScriptFailureDoesNotPoisonNextCall() throws {
    let runtime = try IrisCoreRuntime()
    #expect(throws: (any Error).self) {
      try runtime.validate(
        propertiesJSON: #"[{"col":"title","pattern":"["}]"#,
        afterJSON: #"{"title":"Sample note"}"#)
    }
    #expect(
      try runtime.validate(
        propertiesJSON: properties,
        afterJSON: #"{"title":"Sample note","priority":1}"#
      ).isEmpty)
  }

  @Test func unexpectedResultFailsClosed() throws {
    let runtime = try IrisCoreRuntime(script: "globalThis.IrisCore = {validateRow: () => null}")
    #expect(throws: (any Error).self) {
      try runtime.validate(propertiesJSON: "[]", afterJSON: "{}")
    }
  }
}

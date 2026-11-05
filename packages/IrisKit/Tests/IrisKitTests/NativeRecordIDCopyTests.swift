import Foundation
import Testing

@testable import IrisKit

struct NativeRecordIDCopyTests {
  @Test func selectedIDsKeepTheirOrderAndExactBytes() {
    #expect(NativeRecordIDCopy.text(["row-b", "row-a", "row-b"]) == "row-b\nrow-a")
    #expect(NativeRecordIDCopy.text(["é", "e\u{301}", "é"]) == "é\ne\u{301}")
    #expect(NativeRecordIDCopy.text([" row ", "ROW", "row"]) == " row \nROW\nrow")
  }

  @Test func anEmptySelectionHasNothingToReplaceTheClipboardWith() {
    #expect(NativeRecordIDCopy.text([]) == nil)
    #expect(NativeRecordIDCopy.text(["one-row"]) == "one-row")
  }
}

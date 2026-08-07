import Testing

@testable import App

/// Unit tests for `Int64.formattedByteSize` (issue #1007), the single formatter
/// behind every preformatted `…Formatted` field the API ships.
///
/// It replaced four identical per-DTO copies that divided by 1024 while
/// labelling the result `GB`/`MB`/`KB`. These pin both halves of the fix: the
/// labels are binary, and the tier boundaries round before they are tested, so
/// no value can render as "1024 MiB".
struct ByteSizeFormattingTests {

    @Test("Sizes are labelled in binary units, never GB/MB/KB")
    func labelsAreBinary() {
        #expect(Int64(4 * 1024 * 1024 * 1024).formattedByteSize == "4 GiB")
        #expect(Int64(512 * 1024 * 1024).formattedByteSize == "512 MiB")
        #expect(Int64(64 * 1024).formattedByteSize == "64 KiB")
    }

    @Test("Gibibytes keep one decimal, dropped when the value lands whole")
    func gibibytePrecision() {
        #expect(Int64(1_503_238_553).formattedByteSize == "1.4 GiB")
        // 2.04 GiB rounds to a whole number of gibibytes: "2 GiB", not "2.0 GiB".
        #expect(Int64(2_190_433_320).formattedByteSize == "2 GiB")
    }

    @Test("Each tier rounds before the next unit is tested")
    func tierBoundaries() {
        // One byte under a gibibyte would round to 1024 MiB if the unit were
        // chosen first; it promotes to GiB instead.
        #expect(Int64(1024 * 1024 * 1024 - 1).formattedByteSize == "1 GiB")
        #expect(Int64(1024 * 1024 - 1).formattedByteSize == "1 MiB")
        #expect(Int64(1023).formattedByteSize == "1023 B")
        #expect(Int64(1024).formattedByteSize == "1 KiB")
    }

    @Test("Tebibytes are their own tier")
    func tebibytes() {
        #expect(Int64(2 * 1024 * 1024 * 1024 * 1024).formattedByteSize == "2 TiB")
        #expect(Int64(1_649_267_441_664).formattedByteSize == "1.5 TiB")
    }

    @Test("Zero and negative sizes render without inventing a unit")
    func degenerateSizes() {
        #expect(Int64(0).formattedByteSize == "0 B")
        // A stored size is never negative; say so rather than printing "-1 GiB".
        #expect(Int64(-1).formattedByteSize == "—")
    }
}

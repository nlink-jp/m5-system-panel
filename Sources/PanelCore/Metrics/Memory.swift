import Foundation

/// Raw memory counters (from `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`
/// and `vm.swapusage`), kept as plain numbers so the derivation is pure.
public struct MemorySnapshot: Equatable, Sendable {
    /// `internal_page_count`: anonymous pages.
    public var internalPages: UInt64
    /// `purgeable_count`: pages the owner allowed the OS to discard.
    public var purgeablePages: UInt64
    /// `wire_count`.
    public var wiredPages: UInt64
    /// `compressor_page_count`: pages occupied by the compressor.
    public var compressedPages: UInt64
    public var pageSize: UInt64
    /// `hw.memsize`.
    public var totalBytes: UInt64
    /// `xsw_usage.xsu_used` of `vm.swapusage`.
    public var swapUsedBytes: UInt64

    public init(
        internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
        pageSize: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.pageSize = pageSize
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
    }
}

/// The memory figures the panel shows.
///
/// Defined from the counters above, not from Activity Monitor: `app` is internal
/// minus purgeable pages, `used` is app + wired + compressed (the same
/// arithmetic load-spinner uses; whether it equals Activity Monitor's figure is
/// not documented and not claimed).
public struct MemoryBreakdown: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64

    public init(from snapshot: MemorySnapshot) {
        let bytes = { (pages: UInt64) -> UInt64 in
            let product = pages.multipliedReportingOverflow(by: snapshot.pageSize)
            return product.overflow ? .max : product.partialValue
        }
        let appPages = snapshot.internalPages >= snapshot.purgeablePages
            ? snapshot.internalPages - snapshot.purgeablePages : 0
        app = bytes(appPages)
        wired = bytes(snapshot.wiredPages)
        compressed = bytes(snapshot.compressedPages)
        let sum = app.addingReportingOverflow(wired).partialValue
            .addingReportingOverflow(compressed)
        used = sum.overflow ? .max : sum.partialValue
        total = snapshot.totalBytes
        swapUsed = snapshot.swapUsedBytes
    }
}

/// Memory pressure as `DispatchSource.makeMemoryPressureSource` reports it.
public enum MemoryPressure: Int, Equatable, Sendable {
    case normal = 0, warning = 1, critical = 2
}

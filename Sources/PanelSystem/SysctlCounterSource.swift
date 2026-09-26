// Copied from util-series/net-meter bcdefee Sources/NetMeterSystem/SysctlCounterSource.swift — keep in step with the original.
import Darwin
import PanelCore

/// Reads every interface's counters with one `sysctl` (`NET_RT_IFLIST2`).
///
/// No privilege, entitlement or TCC grant is involved. What comes back is not the
/// raw kernel value: the byte counters are the true value modulo 2^32, floored to
/// 1 KiB (see net-meter's ADR-0001). That is `RateRule`'s business; this type only reads.
public struct SysctlCounterSource: CounterSource {
    public init() {}

    public func read() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        // The list can grow between the size query and the read; retry a few times.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
            length += length / 8  // headroom for an interface appearing in between
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 {
                return Self.parse(buffer, length: length)
            }
            guard errno == ENOMEM else { return [:] }
        }
        return [:]
    }

    private static func parse(_ buffer: [UInt8], length: Int) -> [String: InterfaceCounters] {
        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        let data = message.ifm_data
                        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        result[name] = InterfaceCounters(
                            rxBytes: data.ifi_ibytes,
                            txBytes: data.ifi_obytes,
                            rxPackets: data.ifi_ipackets,
                            txPackets: data.ifi_opackets,
                            linkSpeed: data.ifi_baudrate
                        )
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}

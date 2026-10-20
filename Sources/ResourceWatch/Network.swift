import Foundation
import Darwin

struct NetworkCounter: Sendable { var received: UInt64; var sent: UInt64 }
struct NetworkMetrics: Sendable {
    var download = 0.0
    var upload = 0.0
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var interfaces: [String] = []
}

struct NetworkTracker {
    private var previous: [String: NetworkCounter] = [:]
    private var totals = NetworkMetrics()
    mutating func update(_ counters: [String: NetworkCounter], elapsed: TimeInterval) -> NetworkMetrics {
        var received: UInt64 = 0, sent: UInt64 = 0
        for (name, value) in counters {
            guard let old = previous[name] else { continue }
            // Counter resets, reconnects and newly attached interfaces establish a new baseline.
            if value.received >= old.received { received += value.received - old.received }
            if value.sent >= old.sent { sent += value.sent - old.sent }
        }
        previous = counters
        totals.received += received; totals.sent += sent
        totals.download = elapsed > 0 ? Double(received) / elapsed : 0
        totals.upload = elapsed > 0 ? Double(sent) / elapsed : 0
        totals.interfaces = counters.keys.sorted()
        return totals
    }
}

func networkCounters() throws -> [String: NetworkCounter] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    guard sysctl(&mib, 6, nil, &size, nil, 0) == 0 else { throw CocoaError(.fileReadUnknown) }
    var buffer = [UInt8](repeating: 0, count: size + 4096)
    size = buffer.count
    guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { throw CocoaError(.fileReadUnknown) }
    return buffer.withUnsafeBytes { raw in
        var offset = 0, counters: [String: NetworkCounter] = [:]
        // All routing messages share only the first four bytes. Address records may
        // be shorter than if_msghdr; skip them without abandoning later interfaces.
        while offset + 4 <= size {
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            let type = raw.load(fromByteOffset: offset + 3, as: UInt8.self)
            guard length >= 4, offset + length <= size else { break }
            if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                    let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    // Count physical Wi-Fi/Ethernet once; omit loopback, VPN tunnels and bridges.
                    if text.hasPrefix("en"), info.ifm_flags & IFF_UP != 0 {
                        counters[text] = NetworkCounter(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
            }
            offset += length
        }
        return counters
    }
}

import Foundation
import Darwin
import SystemConfiguration

func kernelValue<T>(_ name: String, _ initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let status = withUnsafeMutableBytes(of: &value) {
        sysctlbyname(name, $0.baseAddress, &size, nil, 0)
    }
    return status == 0 ? value : nil
}

func cpuTicks() -> [UInt32]? {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var ticks = [Int32](repeating: 0, count: 4)
    var count = mach_msg_type_number_t(ticks.count)
    guard host_statistics(host, HOST_CPU_LOAD_INFO, &ticks, &count) == KERN_SUCCESS else { return nil }
    return ticks.map { UInt32(bitPattern: $0) }
}

func memoryUsed() -> UInt64? {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / 4)
    let status = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return nil }
    let pages = max(0, Int64(vm.internal_page_count) - Int64(vm.purgeable_count))
        + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
    return UInt64(pages) * UInt64(getpagesize())
}

struct Link {
    let name: String
    let input: UInt32
    let output: UInt32
}

func physicalLink() -> Link? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var interfaces = [String: Link]()
    var entry = list
    while let current = entry {
        let item = current.pointee
        entry = item.ifa_next
        let name = String(cString: item.ifa_name)
        guard name.hasPrefix("en"), item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
              item.ifa_flags & UInt32(IFF_RUNNING) != 0, let data = item.ifa_data else { continue }
        let counters = data.assumingMemoryBound(to: if_data.self).pointee
        interfaces[name] = Link(name: name, input: counters.ifi_ibytes, output: counters.ifi_obytes)
    }
    for family in ["IPv4", "IPv6"] {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
        if let name = global?["PrimaryInterface"] as? String, let link = interfaces[name] { return link }
    }
    return interfaces.count == 1 ? interfaces.values.first : nil
}

func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
func traffic(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
}

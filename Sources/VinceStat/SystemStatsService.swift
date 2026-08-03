import Darwin
import Foundation

/// CPU / 메모리 샘플러. Mach 호출만 사용하며 권한이 필요 없다.
final class SystemStatsService {
    private var previousTicks: (busy: Double, total: Double)?

    /// 전체 코어 합산 CPU 사용률(0~100). 직전 호출과의 tick 델타로 계산하므로
    /// 첫 호출은 nil을 반환한다.
    func sampleCPUPercent() -> Double? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var load = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = Double(load.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previousTicks = (busy, total) }
        guard let prev = previousTicks else { return nil }

        let deltaTotal = total - prev.total
        guard deltaTotal > 0 else { return nil }
        return min(100, max(0, (busy - prev.busy) / deltaTotal * 100))
    }

    /// 사용 중 메모리(GB). 활성 + wired + 압축 페이지 기준 — 활동 모니터의 "사용된 메모리"와 유사.
    func sampleMemoryUsedGB() -> Double? {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let usedPages = Double(stats.active_count)
            + Double(stats.wire_count)
            + Double(stats.compressor_page_count)
        return usedPages * Double(pageSize) / 1_073_741_824
    }
}

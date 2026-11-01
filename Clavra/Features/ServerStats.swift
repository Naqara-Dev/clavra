import Foundation

/// A server's vitals, read with one small shell script over an exec channel. Linux first; macOS and
/// the BSDs fill in what they can.
struct ServerStats: Equatable, Sendable {
    var load: Double?
    var cpus: Int?
    /// Percent of memory in use, not counting what the kernel can hand back.
    var memory: Int?
    /// Percent used on `/`.
    var disk: Int?
    var uptime: TimeInterval?
    /// TCP ports listening on loopback or every address, apart from SSH's own.
    var ports: [Int] = []

    static let script = #"""
    LC_ALL=C; export LC_ALL
    echo "load $(cut -d' ' -f1 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
    echo "cpus $(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
    awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "mem %d\n",(t-a)*100/t}' /proc/meminfo 2>/dev/null
    df -P / 2>/dev/null | awk 'NR==2{sub("%","",$5);print "disk",$5}'
    awk '{printf "up %d\n",$1}' /proc/uptime 2>/dev/null
    if command -v ss >/dev/null 2>&1; then ss -ltnH; elif [ "$(uname)" = Linux ]; then netstat -ltn | tail -n +3; else netstat -anp tcp | grep LISTEN; fi 2>/dev/null | awk '{print "port", $4}'
    true
    """#

    init(_ text: String, sshPort: Int) {
        var ports = Set<Int>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "load": load = Double(value)
            case "cpus": cpus = Int(value)
            case "mem": memory = Int(value)
            case "disk": disk = Int(value)
            case "up": uptime = TimeInterval(value)
            case "port":
                // Above 32767 is where systems hand out temporary ports; services rarely live there.
                if let port = Self.port(value), port != sshPort, port != 22, port != 53, port < 32_768 { ports.insert(port) }
            default: break
            }
        }
        self.ports = ports.sorted()
    }

    /// `127.0.0.1:5432`, `[::]:80`, `*:3000`, `:::8080`, `0.0.0.0:6379`, and the BSD spelling
    /// `127.0.0.1.5432` or `*.80`. Ports bound to a public address only are left out; they don't
    /// need a tunnel.
    static func port(_ address: String) -> Int? {
        let separator: Character = address.contains(":") ? ":" : "."
        guard let split = address.lastIndex(of: separator), let port = Int(address[address.index(after: split)...]), port > 0 else { return nil }
        var host = String(address[..<split]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        let open = ["", "*", "0.0.0.0", "::", "::1", "127.0.0.1", "localhost", "::ffff:127.0.0.1"]
        return open.contains(host) || host.hasPrefix("127.") ? port : nil
    }

    var isLoadHigh: Bool { (load ?? 0) > Double(max(cpus ?? 1, 1)) }
    var isMemoryHigh: Bool { (memory ?? 0) >= 90 }
    var isDiskHigh: Bool { (disk ?? 0) >= 90 }

    var uptimeText: String? {
        guard let uptime else { return nil }
        let days = Int(uptime / 86_400)
        if days > 0 { return "up \(days)d" }
        let hours = Int(uptime / 3600)
        return hours > 0 ? "up \(hours)h" : "up \(Int(uptime / 60))m"
    }
}

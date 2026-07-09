import Foundation

/// 上报主机名（对齐 Node detectHostname）：macOS 上 hostname 常因网络反查返回
/// "bogon"（多台机器会撞名），此时改取用户在「系统设置」里设的稳定机器名 ComputerName。
func detectHostname() async -> String {
    let h = ProcessInfo.processInfo.hostName
    if h.isEmpty || h == "bogon" || h == "localhost" {
        let r = await ProcessRunner.run("/usr/sbin/scutil", ["--get", "ComputerName"])
        let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0, !name.isEmpty { return name }
    }
    return h
}

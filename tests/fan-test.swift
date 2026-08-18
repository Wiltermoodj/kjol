import Foundation

@objc(KjolHelperProtocol)
protocol KjolHelperProtocol {
    func getFanStatus(reply: @escaping ([String: Any]) -> Void)
    func setFanProfile(_ profile: String, rpmPercent: Double, reply: @escaping (Bool, String) -> Void)
}

let conn = NSXPCConnection(machServiceName: "com.lappier.kjol.helper", options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: KjolHelperProtocol.self)
conn.resume()
guard let proxy = conn.remoteObjectProxy as? KjolHelperProtocol else {
    print("FAIL: no proxy"); exit(1)
}

let sem = DispatchSemaphore(value: 0)
func status(_ tag: String) {
    proxy.getFanStatus { s in
        let fans = (s["fans"] as? [[Double]]) ?? []
        let t = (s["socTemp"] as? Double).map { String(format: "%.1f°C", $0) } ?? "n/a"
        let fansStr = fans.map { "f\(Int($0[0])): act=\(Int($0[1])) tgt=\(Int($0[2])) mode=\(Int($0[5]))" }.joined(separator: " | ")
        print("\(tag): profile=\(s["profile"] ?? "?") temp=\(t) \(fansStr)")
        sem.signal()
    }
    sem.wait()
}

let profile = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "auto"
let pct = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 50 : 50

status("BEFORE")
proxy.setFanProfile(profile, rpmPercent: pct) { ok, msg in
    print("SET-\(profile.uppercased()): ok=\(ok) msg=\(msg)")
    sem.signal()
}
sem.wait()
Thread.sleep(forTimeInterval: 3)
status("AFTER")

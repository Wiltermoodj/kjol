import Foundation

@objc(KjolHelperProtocol)
protocol KjolHelperProtocol {
    func setPowerMode(_ mode: String, reply: @escaping (Bool, String) -> Void)
    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    func getStatus(reply: @escaping ([String: Any]) -> Void)
}

let conn = NSXPCConnection(machServiceName: "com.lappier.kjol.helper", options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: KjolHelperProtocol.self)
conn.resume()

let sem = DispatchSemaphore(value: 0)
var okCount = 0

guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
    print("XPC-ERROR: \(err)")
    exit(2)
}) as? KjolHelperProtocol else {
    print("FAIL: could not get proxy")
    exit(1)
}

proxy.getStatus { status in
    print("STATUS-1: \(status)")
    okCount += 1
    sem.signal()
}
if sem.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT getStatus"); exit(3) }

proxy.setAlwaysOn(true) { ok, msg in
    print("ALWAYS-ON-TRUE: ok=\(ok) msg=\(msg)")
    okCount += 1
    sem.signal()
}
if sem.wait(timeout: .now() + 20) == .timedOut { print("TIMEOUT setAlwaysOn"); exit(3) }

proxy.getStatus { status in
    print("STATUS-2: \(status)")
    okCount += 1
    sem.signal()
}
if sem.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT getStatus2"); exit(3) }

proxy.setAlwaysOn(false) { ok, msg in
    print("ALWAYS-ON-FALSE: ok=\(ok) msg=\(msg)")
    okCount += 1
    sem.signal()
}
if sem.wait(timeout: .now() + 20) == .timedOut { print("TIMEOUT setAlwaysOn off"); exit(3) }

print("PASS: \(okCount)/4 calls succeeded")

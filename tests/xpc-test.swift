import Foundation

@objc(KjolHelperProtocol)
protocol KjolHelperProtocol {
    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, NSError?) -> Void)
    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, NSError?) -> Void)
    func getStatus(reply: @escaping ([String: Any]?, NSError?) -> Void)
    func getCombinedStatus(reply: @escaping ([String: Any]?, NSError?) -> Void)
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

proxy.getCombinedStatus { status, err in
    print("STATUS-1: \(String(describing: status)) err=\(String(describing: err))")
    if err == nil { okCount += 1 }
    sem.signal()
}
if sem.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT getCombinedStatus"); exit(3) }

proxy.setAlwaysOn(true) { ok, err in
    print("ALWAYS-ON-TRUE: ok=\(ok) err=\(String(describing: err))")
    if ok { okCount += 1 }
    sem.signal()
}
if sem.wait(timeout: .now() + 20) == .timedOut { print("TIMEOUT setAlwaysOn"); exit(3) }

proxy.getCombinedStatus { status, err in
    print("STATUS-2: \(String(describing: status)) err=\(String(describing: err))")
    if err == nil { okCount += 1 }
    sem.signal()
}
if sem.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT getCombinedStatus2"); exit(3) }

proxy.setAlwaysOn(false) { ok, err in
    print("ALWAYS-ON-FALSE: ok=\(ok) err=\(String(describing: err))")
    if ok { okCount += 1 }
    sem.signal()
}
if sem.wait(timeout: .now() + 20) == .timedOut { print("TIMEOUT setAlwaysOn off"); exit(3) }

print("PASS: \(okCount)/4 calls succeeded")

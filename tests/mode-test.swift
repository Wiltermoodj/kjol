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
guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in print("XPC-ERROR: \(e)"); exit(2) }) as? KjolHelperProtocol else { exit(1) }

let alwaysOnArg = CommandLine.arguments.count > 1 ? (CommandLine.arguments[1] == "true" || CommandLine.arguments[1] == "1") : true
proxy.setAlwaysOn(alwaysOnArg) { ok, err in
    print("ALWAYS-ON-\(alwaysOnArg): ok=\(ok) err=\(String(describing: err))")
    sem.signal()
}
if sem.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT"); exit(3) }
proxy.getCombinedStatus { s, err in
    print("STATUS: \(String(describing: s)) err=\(String(describing: err))")
    sem.signal()
}
_ = sem.wait(timeout: .now() + 10)

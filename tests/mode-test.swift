// mode-test.swift — verifies setPowerMode round-trips through the helper.
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
guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in print("XPC-ERROR: \(e)"); exit(2) }) as? KjolHelperProtocol else { exit(1) }

let modeArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "serving"
proxy.setPowerMode(modeArg) { ok, msg in
    print("MODE-\(modeArg): ok=\(ok) msg=\(msg)")
    sem.signal()
}
if sem.wait(timeout: .now() + 60) == .timedOut { print("TIMEOUT"); exit(3) }
proxy.getStatus { s in print("STATUS: \(s)"); sem.signal() }
_ = sem.wait(timeout: .now() + 10)

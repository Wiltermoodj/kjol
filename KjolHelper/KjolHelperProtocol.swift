
import Foundation

@objc(KjolHelperProtocol)
protocol KjolHelperProtocol {
    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, String) -> Void)

    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, String) -> Void)

    func getStatus(reply: @escaping ([String: Any]) -> Void)


    func getFanStatus(reply: @escaping ([String: Any]) -> Void)

    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, reply: @escaping (Bool, String) -> Void)
}

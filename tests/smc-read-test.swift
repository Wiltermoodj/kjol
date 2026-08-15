// smc-read-test.swift — unprivileged SMC read test.
import Foundation

let fc = FanController.shared
print("fanCount:", fc.fanCount)
for f in fc.allFans() {
    print(String(format: "fan %d: actual=%.0f target=%.0f min=%.0f max=%.0f mode=%d",
                 f.index, f.actualRPM, f.targetRPM, f.minRPM, f.maxRPM, f.mode))
}
print("socTemp:", fc.socTemperature().map { String(format: "%.1f°C", $0) } ?? "n/a")

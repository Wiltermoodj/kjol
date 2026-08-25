import Foundation

/// Checks status of the privileged helper (LaunchDaemon) that performs
/// root-level operations on behalf of the Kjol app.
///
/// The helper is installed via the Kjol installer package (.pkg) to
/// /Library/PrivilegedHelperTools/ and registered as a system LaunchDaemon.
final class HelperInstaller {

    static let helperLabel = "com.lappier.kjol.helper"
    static let dstBin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
    static let dstPlist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"

    /// True if a helper daemon is registered/enabled at the system level.
    static func isHelperInstalled() -> Bool {
        let binExists = FileManager.default.fileExists(atPath: dstBin)
        let plistExists = FileManager.default.fileExists(atPath: dstPlist)
        let bootstrapped = launchctlStatus() == 0
        return binExists && plistExists && bootstrapped
    }

    /// True if the on-disk helper matches the one bundled with this app build.
    static func isHelperUpToDate() -> Bool {
        guard let bundled = bundleHelperURL(),
              let bundledData = try? Data(contentsOf: bundled),
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: dstBin)),
              bundledData.count == installedData.count else {
            return false
        }
        return bundledData == installedData
    }

    private static func bundleHelperURL() -> URL? {
        guard let path = Bundle.main.path(
            forResource: "com.lappier.kjol.helper",
            ofType: nil,
            inDirectory: "Contents/Library/LaunchDaemons"
        ) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Returns 0 if the daemon is currently bootstrapped/loaded, non-zero otherwise.
    private static func launchctlStatus() -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list", helperLabel]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }
}

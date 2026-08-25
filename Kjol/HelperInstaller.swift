import Foundation
import ServiceManagement

final class HelperInstaller {
    static func isHelperInstalled() -> Bool {
        if #available(macOS 13.0, *) {
            let daemonService = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
            return daemonService.status == .enabled
        } else {
            let plist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"
            let bin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
            return FileManager.default.fileExists(atPath: plist) && FileManager.default.fileExists(atPath: bin)
        }
    }

    func install(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if #available(macOS 13.0, *) {
                let service = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
                if service.status == .enabled {
                    DispatchQueue.main.async { completion(true, nil) }
                    return
                }
                do {
                    try service.register()
                    DispatchQueue.main.async { completion(true, nil) }
                    return
                } catch {
                }
            }

            self.installManual(completion: completion)
        }
    }

    private func installManual(completion: @escaping (Bool, String?) -> Void) {
        let bundlePath = Bundle.main.bundlePath
        let srcBin = "\(bundlePath)/Contents/Library/LaunchDaemons/com.lappier.kjol.helper"
        let tmpPlist = "\(bundlePath)/Contents/Library/LaunchDaemons/com.lappier.kjol.helper.plist"
        let dstBin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
        let dstPlist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"

        let privilegedCommands = """
        /bin/launchctl bootout system/com.lappier.kjol.helper 2>/dev/null || true
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/log
        /bin/cp '\(srcBin)' '\(dstBin)'
        /usr/sbin/chown root:wheel '\(dstBin)'
        /bin/chmod 755 '\(dstBin)'
        /bin/cp '\(tmpPlist)' '\(dstPlist)'
        /usr/sbin/chown root:wheel '\(dstPlist)'
        /bin/chmod 644 '\(dstPlist)'
        /bin/launchctl bootstrap system '\(dstPlist)'
        /bin/launchctl enable system/com.lappier.kjol.helper || true
        """

        let osascriptCmd = """
        do shell script "\(privilegedCommands)" with administrator privileges
        """

        var authFailed = false
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osascriptCmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8),
               (output.contains("execution error") || output.contains("User canceled")) {
                authFailed = true
            }
        } catch {
            authFailed = true
        }

        let installed = HelperInstaller.isHelperInstalled()
        DispatchQueue.main.async {
            if authFailed {
                completion(false, "Admin authorization was cancelled or failed for manual helper installation.")
            } else if installed {
                completion(true, nil)
            } else {
                completion(false, "Manual helper installation failed.")
            }
        }
    }
}

import Foundation
import Combine
import AppKit
import SwiftUI

enum UpdateState: Equatable {
    case idle
    case checking
    case available(UpdateInfo)
    case upToDate
    case downloading(progress: Double)
    case readyToInstall(pkgLocalURL: URL)
    case error(String)

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate):
            return true
        case (.available(let a), .available(let b)):
            return a.version == b.version
        case (.downloading(let a), .downloading(let b)):
            return a == b
        case (.readyToInstall(let a), .readyToInstall(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

final class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
    private let service = UpdateCheckerService()
    private var lastCheckDate: Date?

    func checkForUpdates(silent: Bool = false) {
        if silent {
            if let last = lastCheckDate, Date().timeIntervalSince(last) < 3600 {
                return
            }
        }

        if case .downloading = state { return }
        if case .readyToInstall = state { return }

        state = .checking
        lastCheckDate = Date()

        Task {
            do {
                if let updateInfo = try await service.checkForUpdates() {
                    DispatchQueue.main.async {
                        self.state = .available(updateInfo)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.state = .upToDate
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if !silent {
                        self.state = .error(error.localizedDescription)
                    } else {
                        self.state = .idle
                    }
                }
            }
        }
    }

    func startDownload(for info: UpdateInfo) {
        state = .downloading(progress: 0.0)
        Task {
            do {
                let localURL = try await service.downloadInstaller(from: info.pkgDownloadURL) { progress in
                    self.state = .downloading(progress: progress)
                }
                await MainActor.run {
                    self.state = .readyToInstall(pkgLocalURL: localURL)
                    self.installUpdate(localURL: localURL)
                }
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    func installUpdate(localURL: URL) {
        NSWorkspace.shared.open(localURL)
    }
}

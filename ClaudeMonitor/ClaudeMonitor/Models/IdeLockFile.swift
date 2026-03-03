import Foundation
import AppKit

// MARK: - IDE Lock File (Codable)

struct IdeLockFile: Codable {
    let pid: Int32
    let workspaceFolders: [String]
    let ideName: String
}

// MARK: - IDE Info (View layer)

struct IdeInfo: Equatable {
    let ideName: String
    let pid: pid_t
    let isRunning: Bool
    let workspaceFolder: String
    let appBundlePath: String?
    let appIcon: NSImage  // cached at creation time

    var shortName: String {
        switch ideName {
        case "Visual Studio Code": return "VS Code"
        case "IntelliJ IDEA":      return "IntelliJ"
        default:                   return ideName
        }
    }

    static func == (lhs: IdeInfo, rhs: IdeInfo) -> Bool {
        lhs.ideName == rhs.ideName
            && lhs.pid == rhs.pid
            && lhs.isRunning == rhs.isRunning
            && lhs.workspaceFolder == rhs.workspaceFolder
            && lhs.appBundlePath == rhs.appBundlePath
    }
}

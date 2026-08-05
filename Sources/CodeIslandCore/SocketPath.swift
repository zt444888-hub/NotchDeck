import Foundation
import Darwin

public enum SocketPath {
    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEISLAND_SOCKET_PATH"] {
            return env
        }
        // Keep in sync with hook scripts / resources: all hooks connect to
        // /tmp/notchdeck-<uid>.sock (rebrand 2026-08-05; was codeisland-<uid>.sock).
        return "/tmp/notchdeck-\(getuid()).sock"
    }
}

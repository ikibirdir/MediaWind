// Sends test commands to a PhotoViewer launched with PHOTOVIEWER_DEBUG=1 (see DebugHook.swift).
//
//   swiftc -O scripts/pvdebug.swift -o .build/pvdebug
//   .build/pvdebug "key 124" "wait 300" "state /tmp/pv.json"
//
// Each argument is one command; "wait <ms>" pauses; "state <path>" also prints the JSON.
import Foundation

let name = Notification.Name("com.ikibirdir.PhotoViewer.debug")

func post(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(name, object: command, userInfo: nil,
                                                                 deliverImmediately: true)
}

func pause(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

for argument in CommandLine.arguments.dropFirst() {
    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "wait":
        pause((Double(parts.count > 1 ? parts[1] : "0") ?? 0) / 1000)
    case "state", "snapshot":
        let path = parts.count > 1 ? parts[1] : NSTemporaryDirectory() + "pv-\(parts[0]).out"
        try? FileManager.default.removeItem(atPath: path)
        post("\(parts[0]) \(path)")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path) && Date() < deadline { pause(0.02) }
        if parts[0] == "state" {
            print((try? String(contentsOfFile: path, encoding: .utf8)) ?? "no state (timed out)")
        } else {
            print(FileManager.default.fileExists(atPath: path) ? "snapshot: \(path)" : "no snapshot (timed out)")
        }
    default:
        post(argument)
    }
}

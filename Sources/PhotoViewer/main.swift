import AppKit

Perf.launch = CFAbsoluteTimeGetCurrent()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so backstop.sh can borrow the app's kernel-level
// identity check (see ResumeFrozenCommand), which ends itself when its
// lifetime is up. Anything else starts the menu bar app.
if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst()), endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
// `Insomnia lease <minutes>` and `Insomnia lease-end` hand a request to the
// running app and never start one (LeaseCommand).
if let output = LeaseCommand.run(Array(CommandLine.arguments.dropFirst())) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()

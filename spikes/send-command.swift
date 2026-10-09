// Sends a command to the running app, e.g.:
//   swift spikes/send-command.swift pause
//   swift spikes/send-command.swift seek:-10
//   swift spikes/send-command.swift window:stash --port 47899   (a copy started with --port)
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var name = "local.pipanywhere.command"
if let i = args.firstIndex(of: "--port"), i + 1 < args.count {
    name += ".\(args[i + 1])"
    args.removeSubrange(i...(i + 1))
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: args.first ?? "toggle", userInfo: nil, deliverImmediately: true)

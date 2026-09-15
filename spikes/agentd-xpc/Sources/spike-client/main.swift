import Foundation
import SpikeShared

let label = CommandLine.arguments.dropFirst().first ?? "client"
print(pingAgentd(from: "\(label) pid=\(getpid()) ppid=\(getppid())"))

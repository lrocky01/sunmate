import Foundation

// A standalone macOS harness exercises the same offline Core Audio conversion.
// No Flutter engine, physical phone, microphone, BLE, or network is required.
do {
  guard [3, 4].contains(CommandLine.arguments.count) else { exit(64) }
  let files = RecorderAudioFiles(supportRoot: URL(fileURLWithPath: CommandLine.arguments[1]))
  let result: [String: Any]
  if CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "verify-playback" {
    _ = try files.validatePlayback(CommandLine.arguments[2])
    result = ["valid": true]
  } else {
    result = try files.prepare(CommandLine.arguments[2])
  }
  let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
} catch {
  fputs("Local audio conversion rejected input: \(error.localizedDescription)\n", stderr)
  exit(1)
}

import Foundation
import AVFoundation

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
var checks = 0
func check(_ yes: Bool, _ name: String) throws {
  if !yes { throw NSError(domain: name, code: 1) }; checks += 1
}
func rejects(_ name: String, _ work: () throws -> Void) throws {
  var rejected = false
  do { try work() } catch { rejected = true }
  try check(rejected, name)
}
func pcm(_ frames: Int) -> Data {
  var bytes = Data()
  for i in 0..<frames { let sample = Int16(truncatingIfNeeded: i * 59); bytes.append(UInt8(truncatingIfNeeded: sample)); bytes.append(UInt8(truncatingIfNeeded: sample >> 8)) }
  return bytes
}
let now = Date(timeIntervalSince1970: 1793491200)
for purpose in WatchRecordingPurpose.allCases {
  let dir = base.appendingPathComponent(purpose.rawValue)
  let store = try WatchRecordingStore(root: dir, framesPerPart: 160)
  try check(!store.policy.enabled && !store.policy.backgroundSync, "defaults")
  try rejects("disabled") { try store.begin(purpose, now: now) }
  try store.setPolicy(WatchRecordingPolicy(enabled: true, backgroundSync: false))
  try store.begin(purpose, now: now)
  try rejects("second start") { try store.begin(purpose, now: now) }
  let bytes = pcm(450); try store.append(bytes)
  try check(store.active?.parts.count == 2, "only closed parts")
  let value = try store.finish(now: now.addingTimeInterval(1))
  try check(value.complete && value.parts.map(\.frames) == [160,160,130], "tail")
  try check(value.parts.map(\.offsetFrames) == [0,160,320], "sample positions")
  var restored = Data()
  for p in value.parts {
    let file = try store.file(p), data = try Data(contentsOf: file)
    restored.append(data.dropFirst(44))
    let decoded = try AVAudioFile(forReading: file)
    try check(decoded.length == p.frames && decoded.processingFormat.sampleRate == 16000, "real WAV decode")
  }
  try check(restored == bytes, "no dropped or duplicated samples")
  let receiver = try WatchRecordingStore(root: base.appendingPathComponent("receiver-" + purpose.rawValue))
  try rejects("manifest before files") { try receiver.importManifest(value) }
  try receiver.importPart(value.parts[2], from: store.file(value.parts[2]))
  try rejects("missing middle") { try receiver.importManifest(value) }
  try receiver.importPart(value.parts[0], from: store.file(value.parts[0]))
  try receiver.importPart(value.parts[1], from: store.file(value.parts[1]))
  try receiver.importManifest(value); try receiver.importManifest(value)
  try check(try receiver.manifests().count == 1, "idempotent import")
  let part = value.parts[0], original = try Data(contentsOf: receiver.file(part))
  let bad = base.appendingPathComponent("tamper.wav"); var corrupted = original; corrupted[44] ^= 1; try corrupted.write(to: bad)
  try rejects("checksum mismatch") { try receiver.importPart(part, from: bad) }
  try check(try Data(contentsOf: receiver.file(part)) == original, "original retained")
  try check(try store.pendingParts().count == 3, "transport does not acknowledge")
  try store.acknowledge(part)
  let sha = WatchRecordingStore.hash(try WatchRecordingStore.encoder.encode(value))
  try store.acknowledgeManifest(sha)
  let reopened = try WatchRecordingStore(root: dir, framesPerPart: 160)
  try check(try reopened.pendingParts().count == 2 && reopened.hasManifestReceipt(sha), "durable receipts")
  var gap = value; gap.parts.remove(at: 1)
  try rejects("noncontiguous manifest") { try receiver.importManifest(gap) }
  var wrong = part; wrong.source = "../escape"
  try rejects("path traversal") { try receiver.importPart(wrong, from: store.file(part)) }
}
let recoveryDir = base.appendingPathComponent("recovery")
do {
  let store = try WatchRecordingStore(root: recoveryDir, framesPerPart: 160)
  try store.setPolicy(WatchRecordingPolicy(enabled: true))
  try store.begin(.meeting, now: now); try store.append(pcm(193))
}
let recovered = try WatchRecordingStore(root: recoveryDir, framesPerPart: 160)
let interrupted = try recovered.manifests()[0]
try check(interrupted.interrupted && !interrupted.complete, "crash is not normal completion")
try check(interrupted.parts.map(\.frames) == [160,33], "recover durable open PCM")
let link = base.appendingPathComponent("symlink")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: recoveryDir)
try rejects("symlink root") { _ = try WatchRecordingStore(root: link) }
print("{\"checks\":\(checks),\"purposes\":3,\"realWavDecode\":true}")

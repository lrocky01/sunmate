import Foundation
import CoreBluetooth

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
let sn = "AB00000000000001", session: Int64 = 1792496000000
let cmd = CBCharacteristic("00010203-0405-0607-0809-0a0b0c0d2b30")
let event = CBCharacteristic("00010203-0405-0607-0809-0a0b0c0d2b31")
let audio = CBCharacteristic("00010203-0405-0607-0809-0a0b0c0d2b33")
let card = CBPeripheral(); card.services = [CBService([cmd,event,audio])]
var flags = [String: Bool]()
for key in ["receive", "meetingUpload", "lifelogUpload", "meetingAsr", "lifelogAsr", "meetingSummary", "lifelogSummary", "cellular"] { flags[key] = key == "receive" }
let transfer = try RecorderBackgroundTransfer(root: root, initialPlan: ["policy": flags, "revision": 1, "target": "synthetic-target"])
let receiver = try RecorderBackgroundReceiver(transfer: transfer)
func emit(_ chr: CBCharacteristic, _ data: Data) {
  chr.value = data
  let packet = NSMutableDictionary(dictionary: ["peripheral": card, "characteristic": chr, "handled": false])
  NotificationCenter.default.post(name: .init("SunMateRecorderValue"), object: packet)
}
var source = Data()
for _ in 0..<50 { source.append(contentsOf: [3,0,0,0,0,0,0,0,0xf8,0xff,0xfe]) }
var reads: [String] = []
card.writer = { bytes in
  DispatchQueue.main.async {
    if bytes == Data([0x11,0x22]) {
      for p in 0...1 {
        emit(event, Data([0xaa,0x55,8]) + Data("/record/longops_s\(session)_p000\(p).ops \(source.count)".utf8))
      }
      emit(event, Data([0xaa,0x55,8]))
    } else if bytes.starts(with: [0x11,0x26]) {
      let name = String(data: bytes.dropFirst(2), encoding: .utf8)!
      reads.append(name)
      let size = mode == "bad-size" ? source.count + 1 : source.count
      emit(event, Data([0xaa,0x55,5,UInt8(truncatingIfNeeded: size >> 24),UInt8(truncatingIfNeeded: size >> 16),UInt8(truncatingIfNeeded: size >> 8),UInt8(truncatingIfNeeded: size)]))
      // Completion can arrive on 2b31 before the final 2b33 data notification.
      emit(event, Data([0xaa,0x55,6]))
      emit(audio, source.prefix(200)); emit(audio, source.dropFirst(200))
    } else if bytes.starts(with: [0x11,0x30]) {
      let v: [String: Any] = ["method": "reportStatus", "params": ["recording": ["is_long_recording": true, "long_session": session, "long_part": 1]]]
      let json = try! JSONSerialization.data(withJSONObject: v)
      emit(event, Data([0xaa,0x55,0x30,0,0]) + json.prefix(35))
      emit(event, json.dropFirst(35))
    }
  }
}
NotificationCenter.default.post(name: .init("SunMateRecorderArm"), object: nil, userInfo: ["peripheral": card, "config": ["sn": sn, "purpose": "meeting"]])
try receiver.acquire()
var start = Data([0xaa,0x55,1,1])
for i in (0..<8).reversed() { start.append(UInt8(truncatingIfNeeded: session >> (i * 8))) }
emit(event, start)
let deadline = Date().addingTimeInterval(10)
var stopSent = false
while Date() < deadline {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  let state = receiver.snapshot()
  let rows = state["events"] as? [[String: Any]] ?? []
  if mode == "bad-size", state["poisoned"] as? Bool == true { break }
  if !stopSent && rows.contains(where: { $0["kind"] as? String == "source" }) {
    precondition(reads.count == 1 && reads[0].contains("p0000"), "Open part must never download")
    emit(event, Data([0xaa,0x55,2,1])); stopSent = true
  }
  if rows.contains(where: { $0["kind"] as? String == "finalized" }) { break }
}
var clean: Bool?
receiver.release { clean = $0 }
while clean == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
let snapshot = receiver.snapshot()
let events = snapshot["events"] as? [[String: Any]] ?? []
if mode == "bad-size" {
  precondition(clean == false && !events.contains(where: { $0["kind"] as? String == "source" }))
} else {
  precondition(clean == true && reads.count == 2)
  precondition(events.filter { $0["kind"] as? String == "source" }.count == 2)
  precondition(events.filter { $0["kind"] as? String == "finalized" }.count == 1)
  let dir = root.appendingPathComponent("recorder_long_audio_v1/\(sn)/s\(session)")
  let sourceFile = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("p0-") }!
  let output = dir.appendingPathComponent("synthetic.ogg")
  let (samples,lead) = try RecorderBackgroundFiles.mux(sourceFile, to: output, serial: 1)
  precondition(samples == 48000 && lead == 0)
  let digest = try RecorderBackgroundFiles.sha(sourceFile)
  precondition(digest.count == 64)
  let playable = try RecorderAudioFiles(supportRoot: root).prepare("recorder_long_audio_v1/\(sn)/s\(session)/synthetic.ogg")
  precondition((playable["frames"] as? NSNumber)?.intValue == 16000)
  let restored = try RecorderBackgroundReceiver(transfer: transfer)
  precondition((restored.snapshot()["events"] as? [[String: Any]])?.count == events.count)
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["clean": clean ?? false, "sources": events.filter { $0["kind"] as? String == "source" }.count, "reads": reads.count]))

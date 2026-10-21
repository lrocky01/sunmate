import Foundation
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Flutter)
import Flutter
#endif

/// Shares the vendor plugin's peripheral, delegate and characteristic callbacks.
/// Never initiates pairing, authentication, key exchange, or another connection.
final class RecorderBackgroundReceiver {
  let transfer: RecorderBackgroundTransfer
  var observers: [NSObjectProtocol] = []
  private var peripheral: CBPeripheral?
  private var command: CBCharacteristic?
  private var sn = "", purpose = "meeting"
  private var owner = false, enabled = false, poisoned = false, releasing = false
  private var activeSession: Int64?, activePart: Int?
  private var stopped = Set<Int64>(), closed: [Int64: Set<Int>] = [:]
  private var entries: [String: (Int64, Int, Int)] = [:]
  private var listing = false, reading: String?, expected = 0, received = 0
  private var pendingWrite: Data?
  private var partial: URL?, output: FileHandle?
  private var watchdog: Timer?, poll: Timer?, tail: Timer?
  private var json = Data()
  private var journal: [[String: Any]] = []
  private var metadata: [String: [String: Any]] = [:]
  private var sessionPolicies: [String: [String: Any]] = [:]
  private var sentManifests = Set<String>(), sendingManifests = Set<String>()
  private var releaseCallback: ((Bool) -> Void)?
  private let work = DispatchQueue(label: "sunmate.ble.commit")
  private var committing = false
  private var packaging = false
  private var sizeSeen = false, completionSeen = false
  private var tailCounts: [Int64: Int] = [:]
  private var lastInventory: [Int64: [String]] = [:]

  init(transfer: RecorderBackgroundTransfer) throws {
    self.transfer = transfer
    let file = try journalFile()
    if FileManager.default.fileExists(atPath: file.path),
       let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] {
      journal = value["events"] as? [[String: Any]] ?? []
      metadata = value["segments"] as? [String: [String: Any]] ?? [:]
      sessionPolicies = value["policies"] as? [String: [String: Any]] ?? [:]
      sentManifests = Set(value["manifests"] as? [String] ?? [])
    }
    transfer.changed = { [weak self] in self?.flushManifests() }
    observers.append(NotificationCenter.default.addObserver(forName: .init("SunMateRecorderArm"), object: nil, queue: nil) { [weak self] note in
      guard let self = self, let v = note.userInfo, let p = v["peripheral"] as? CBPeripheral,
            let config = v["config"] as? [String: Any], let sn = config["sn"] as? String,
            sn.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return }
      self.peripheral = p; self.sn = sn
      self.command = p.services?.first { $0.uuid.uuidString.lowercased() == "00010203-0405-0607-0809-0a0b0c0d1930" }?.characteristics?.first { $0.uuid.uuidString.lowercased() == "00010203-0405-0607-0809-0a0b0c0d2b30" }
      self.enabled = (self.transfer.plan["policy"] as? [String: Bool])?["receive"] == true
      self.purpose = config["purpose"] as? String == "lifelog" ? "lifelog" : "meeting"
      self.activeSession = (config["activeSession"] as? NSNumber)?.int64Value
      self.activePart = config["activePart"] as? Int
      if let session = self.activeSession, let policy = config["activePolicy"] as? [String: Any] {
        self.sessionPolicies["\(sn):\(session)"] = policy.merging(["purpose": self.purpose]) { _, n in n }
      }
      self.poisoned = false
    })
    observers.append(NotificationCenter.default.addObserver(forName: .init("SunMateRecorderWritable"), object: nil, queue: nil) { [weak self] note in
      guard let self = self, let p = note.object as? CBPeripheral, p == self.peripheral, let bytes = self.pendingWrite else { return }
      self.pendingWrite = nil; self.send(bytes)
    })
    observers.append(NotificationCenter.default.addObserver(forName: .init("SunMateRecorderDisconnected"), object: nil, queue: nil) { [weak self] note in
      guard let self = self, let p = note.object as? CBPeripheral, p == self.peripheral else { return }; self.disconnected()
    })
    observers.append(NotificationCenter.default.addObserver(forName: .init("SunMateRecorderValue"), object: nil, queue: nil) { [weak self] note in
      guard let box = note.object as? NSMutableDictionary, let p = box["peripheral"] as? CBPeripheral,
            let self = self, p == self.peripheral, self.owner,
            let chr = box["characteristic"] as? CBCharacteristic, let data = chr.value else { return }
      let uuid = chr.uuid.uuidString.lowercased()
      guard chr.service?.uuid.uuidString.lowercased() == "00010203-0405-0607-0809-0a0b0c0d1930" else { return }
      if uuid == "00010203-0405-0607-0809-0a0b0c0d2b33" {
        box["handled"] = true; self.data(data)
      } else if uuid == "00010203-0405-0607-0809-0a0b0c0d2b31" {
        // Suppress only our file/control events. Notifications and realtime still reach Dart.
        if self.event(data) { box["handled"] = true }
      }
    })
  }
  deinit { for item in observers { NotificationCenter.default.removeObserver(item) }; watchdog?.invalidate(); poll?.invalidate(); tail?.invalidate() }
  private func journalFile() throws -> URL {
    try RecorderBackgroundFiles.safeDirectory(transfer.root, ["recorder_background_v1"]).appendingPathComponent("receiver.json")
  }
  private func save() throws {
    guard journal.count < 100000 else { throw RecorderBackgroundError.capacity }
    try JSONSerialization.data(withJSONObject: ["events": journal, "segments": metadata, "policies": sessionPolicies, "manifests": Array(sentManifests)], options: [.sortedKeys]).write(to: journalFile(), options: .atomic)
  }
  private func record(_ kind: String, _ session: Int64, extra: [String: Any] = [:]) throws {
    var row: [String: Any] = ["eventId": UUID().uuidString, "kind": kind, "sn": sn, "session": session, "purpose": purpose, "observed": ISO8601DateFormatter().string(from: Date())]
    if let p = sessionPolicies["\(sn):\(session)"] { row["policy"] = p; row["target"] = p["target"]; row["purpose"] = p["purpose"] ?? purpose }
    for (k, v) in extra { row[k] = v }
    if sessionPolicies["\(sn):\(session)"] == nil { row["purpose"] = NSNull() }
    journal.append(row); try save()
  }
  func acquire() throws {
    guard enabled, !poisoned, peripheral?.state == .connected, command != nil, !owner else { throw RecorderBackgroundError.unauthorized }
    owner = true; releasing = false
    transfer.recover()
    // Current connected GATT is already AES verified by Dart. Any disconnect disarms it.
    queryStatus()
    poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.queryStatus() }
  }
  func release(_ done: @escaping (Bool) -> Void) {
    if !owner { done(!poisoned); return }
    releasing = true; releaseCallback = done; poll?.invalidate(); poll = nil; tail?.invalidate()
    finishRelease()
  }
  private func finishRelease() {
    if releasing && !listing && reading == nil && !committing && !packaging {
      owner = false; releasing = false; watchdog?.invalidate()
      let done = releaseCallback; releaseCallback = nil; done?(!poisoned)
    }
  }
  func snapshot() -> [String: Any] { ["events": journal, "segments": Array(metadata.values), "owner": owner, "poisoned": poisoned, "requiresAuthentication": peripheral == nil] }
  private func flushManifests() {
    for event in journal where event["kind"] as? String == "finalized" {
      guard let serial = event["sn"] as? String, let session = (event["session"] as? NSNumber)?.int64Value,
            let count = event["totalParts"] as? Int, let kind = event["purpose"] as? String,
            let target = event["target"] as? String, target == transfer.plan["target"] as? String else { continue }
      let key = target + ":\(serial):\(session)"
      if sentManifests.contains(key) || sendingManifests.contains(key) { continue }
      let uploads = transfer.snapshot()
      var parts: [String] = []
      for part in 0..<count {
        let source = journal.first { $0["kind"] as? String == "source" && $0["sn"] as? String == serial && ($0["session"] as? NSNumber)?.int64Value == session && $0["part"] as? Int == part }
        let matches = uploads.filter { upload in
          let m = upload["metadata"] as? [String: Any] ?? [:]
          return upload["state"] as? String == "received" && upload["target"] as? String == target && m["session"] as? String == "\(serial):\(session)" && m["part"] as? Int == part && m["sourceSha"] as? String == source?["sha"] as? String
        }
        if matches.count != 1 { break }
        parts.append(matches[0]["id"] as? String ?? "")
      }
      if parts.count != count || parts.isEmpty { continue }
      sendingManifests.insert(key)
      transfer.api("manifest", body: ["session": "\(serial):\(session)", "purpose": kind, "parts": parts, "stopped": true, "tailConfirmed": true, "observedEnd": event["observed"] ?? ""]) { result in
        self.sendingManifests.remove(key)
        if case .success(let value) = result, value["completeManifest"] as? Bool == true { self.sentManifests.insert(key); try? self.save() }
      }
    }
  }
  func prepareSource(_ source: [String: Any], done: @escaping (Result<Void, Error>) -> Void) throws {
    guard !packaging else { throw RecorderBackgroundError.busy }
    guard let sourceSn = source["sn"] as? String, let n = (source["session"] as? NSNumber)?.int64Value,
          let part = source["part"] as? Int, part >= 0, part < 10000, n > 0,
          let sha = source["sha"] as? String, sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let kind = source["purpose"] as? String, ["meeting", "lifelog"].contains(kind) else { throw RecorderBackgroundError.invalid }
    let dir = try RecorderBackgroundFiles.safeDirectory(transfer.root, ["recorder_long_audio_v1", sourceSn, "s\(n)"])
    let ops = dir.appendingPathComponent("p\(part)-\(sha).ops")
    let key = "\(sourceSn):\(n):\(part):\(sha)"
    let sessionPolicy = source["policy"] as? [String: Any] ?? sessionPolicies["\(sourceSn):\(n)"] ?? [:]
    guard sessionPolicy["target"] as? String == transfer.plan["target"] as? String else { done(.success(())); return }
    let flags = sessionPolicy["policy"] as? [String: Bool] ?? [:]
    guard flags[kind + "Upload"] == true else { done(.success(())); return }
    let previousCandidates = metadata.values.filter { v in
      guard let m = v["metadata"] as? [String: Any] else { return false }
      return m["session"] as? String == "\(sourceSn):\(n)" && m["part"] as? Int == part - 1
    }
    let previousSha = source["previousSha"] as? String
    let matching = previousSha == nil ? previousCandidates : previousCandidates.filter { ($0["metadata"] as? [String: Any])?["sourceSha"] as? String == previousSha }
    if part > 0 && matching.count != 1 { throw RecorderBackgroundError.invalid }
    let previous = matching.first
    let contextSha = (previous?["metadata"] as? [String: Any])?["sourceSha"] as? String
    let versionKey = key + ":" + (contextSha ?? "first")
    if let old = metadata[versionKey], let path = old["file"] as? String { transfer.enqueue(URL(fileURLWithPath: path), metadata: old["metadata"] as? [String: Any] ?? [:]); done(.success(())); return }
    let context = (previous?["source"] as? String).map { URL(fileURLWithPath: $0) }
    let output = dir.appendingPathComponent("native-asr-\(part)-\(sha)-\(UUID().uuidString).ogg")
    let previousMeta = previous?["metadata"] as? [String: Any]
    let offset = (previousMeta?["offset48"] as? NSNumber)?.int64Value ?? 0
    let previousSamples = (previousMeta?["samples48"] as? NSNumber)?.int64Value ?? 0
    let start = journal.first { $0["kind"] as? String == "started" && ($0["session"] as? NSNumber)?.int64Value == n && $0["sn"] as? String == sourceSn }?["observed"] as? String
    packaging = true
    work.async {
      do {
        guard try RecorderBackgroundFiles.sha(ops) == sha else { throw RecorderBackgroundError.invalid }
    let (samples, lead) = try RecorderBackgroundFiles.mux(ops, to: output, serial: UInt32(truncatingIfNeeded: n), context: context)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
    let observed = source["observedStart"] as? String ?? start ?? source["observed"] as? String ?? ISO8601DateFormatter().string(from: Date())
    let anchor = Date(timeIntervalSince1970: Double(n) / 1000)
    let startDate = start.flatMap { ISO8601DateFormatter().date(from: $0) }
    let estimated = source["timeConfidence"] as? String == "estimated" || (n >= 1577836800000 && n <= 4102444800000 && startDate != nil && abs(anchor.timeIntervalSince(startDate!)) <= 300)
    let time = source["observedStart"] as? String ?? (estimated ? ISO8601DateFormatter().string(from: anchor) : observed)
    let meta: [String: Any] = ["session": "\(sourceSn):\(n)", "part": part, "purpose": kind, "sourceSha": sha, "contextSha": contextSha as Any? ?? NSNull(), "sha": try RecorderBackgroundFiles.sha(output), "bytes": size, "processAsr": flags[kind + "Asr"] == true, "processSummary": flags[kind + "Summary"] == true,
        "samples48": samples, "lead48": lead, "offset48": part == 0 ? 0 : offset + previousSamples, "observedStart": time, "timeConfidence": estimated ? "estimated" : "unknown"]
    DispatchQueue.main.async {
      self.packaging = false
      do {
        self.metadata[versionKey] = ["metadata": meta, "file": output.path, "source": ops.path]
        try self.save(); self.transfer.enqueue(output, metadata: meta); self.transfer.recover(); done(.success(())); self.finishRelease()
      } catch { done(.failure(error)); self.finishRelease() }
    }
      } catch { DispatchQueue.main.async { self.packaging = false; done(.failure(error)); self.finishRelease() } }
    }
  }
  private func disconnected() {
    if listing || reading != nil { fail() }
    owner = false; enabled = false; peripheral = nil; command = nil
    activeSession = nil; activePart = nil; closed = [:]; stopped = []
    poll?.invalidate(); tail?.invalidate(); finishRelease()
  }
  private func send(_ bytes: Data) {
    guard owner, !poisoned, let p = peripheral, p.state == .connected, let chr = command,
          bytes.count <= p.maximumWriteValueLength(for: .withoutResponse) else { fail(); return }
    if !p.canSendWriteWithoutResponse {
      guard pendingWrite == nil else { fail(); return }
      pendingWrite = bytes; timeout(); return
    }
    p.writeValue(bytes, for: chr, type: .withoutResponse)
  }
  private func timeout() {
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.fail() }
  }
  private func fail() {
    // There is no protocol cancel/transfer-id. Never reuse a timed-out channel.
    pendingWrite = nil; poisoned = true; listing = false; reading = nil; try? output?.close(); output = nil
    watchdog?.invalidate(); poll?.invalidate(); tail?.invalidate(); finishRelease()
  }
  private func queryStatus() {
    guard owner, !releasing, !listing, reading == nil, !committing, !packaging, !poisoned else { return }
    var bytes = Data([0x11, 0x30]); bytes.append(Data("{\"version\":\"1.0.0\",\"method\":\"getStatus\",\"params\":{}}".utf8)); send(bytes)
  }
  private func list() {
    guard owner, !releasing, !listing, reading == nil, !committing, !packaging, !poisoned else { return }
    entries = [:]; listing = true; timeout(); send(Data([0x11, 0x22]))
  }
  private func event(_ incoming: Data) -> Bool {
    let data = Data(incoming)
    if data.count >= 5, data[0] == 0xaa, data[1] == 0x55, data[2] == 0x30 {
      json = Data(data.dropFirst(5))
    } else if !json.isEmpty { json.append(data) }
    if !json.isEmpty {
      if json.count > 8192 { json = Data(); fail(); return false }
      if let v = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
        json = Data()
        if v["method"] as? String == "reportStatus", let p = v["params"] as? [String: Any] {
          let recording = p["recording"] as? [String: Any] ?? p
          let session = (recording["long_session"] as? NSNumber)?.int64Value ?? (p["long_session"] as? NSNumber)?.int64Value
          let part = recording["long_part"] as? Int ?? p["long_part"] as? Int
          if recording["is_long_recording"] as? Bool == true, let n = session, let i = part, n > 0, i >= 0, i < 10000, !stopped.contains(n) {
            if activeSession != n && sessionPolicies["\(sn):\(n)"] == nil { try? record("uncertain", n) }
            activeSession = n; activePart = i
            closed[n, default: []].formUnion(0..<i); list()
          } else if recording["is_long_recording"] as? Bool == false, let n = session, activeSession == n {
            stopped.insert(n); activeSession = nil; activePart = nil
            try? record("stopped", n); list()
          }
        } else if v["method"] as? String == "reportLongOpsSegmentClosed", let p = v["params"] as? [String: Any],
                  let n = (p["session"] as? NSNumber)?.int64Value ?? (p["long_session"] as? NSNumber)?.int64Value,
                  let i = p["part"] as? Int ?? p["long_part"] as? Int, activeSession == n, i >= 0, i < 10000 {
          closed[n, default: []].insert(i); list()
        }
      }
    }
    guard data.count >= 3, data[0] == 0xaa, data[1] == 0x55 else { return false }
    let op = data[2]
    do {
      if op == 1, data.count == 12, data[3] == 0 {
        if let n = activeSession { try record("uncertain", n) }
        activeSession = nil; activePart = nil; closed = [:]
        if reading != nil || listing { fail() }; return false
      }
      if op == 1, data.count == 12, data[3] == 1 {
        let n = data.suffix(8).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        guard n > 0 else { throw RecorderBackgroundError.invalid }
        if stopped.contains(n) || activeSession == n && sessionPolicies["\(sn):\(n)"] != nil { return true }
        activeSession = n; activePart = nil; stopped.remove(n)
        sessionPolicies["\(sn):\(n)"] = ["purpose": purpose, "revision": transfer.plan["revision"] ?? 1, "policy": transfer.plan["policy"] ?? [:], "target": transfer.plan["target"] ?? ""]
        try record("started", n); queryStatus(); return true
      }
      if op == 2, (data.count == 3 || data.count == 4 && data[3] == 1), let session = activeSession {
        stopped.insert(session); activeSession = nil; activePart = nil
        try record("stopped", session); list(); return true
      }
      if op == 8, listing {
        if data.count == 3 { listing = false; watchdog?.invalidate(); try next(); return true }
        guard let text = String(data: data.dropFirst(3), encoding: .utf8) else { throw RecorderBackgroundError.invalid }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        if fields.count >= 2, let size = Int(fields[1]), size > 0, size <= 268435456,
           !fields[0].contains(".."), !fields[0].contains("\\"),
           let basename = fields[0].split(separator: "/").last {
          let name = String(basename)
          let pattern = try NSRegularExpression(pattern: "^longops_s([0-9]{1,19})_p([0-9]{1,6})\\.ops$")
          let ns = name as NSString
          if let m = pattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
             let session = Int64(ns.substring(with: m.range(at: 1))), let part = Int(ns.substring(with: m.range(at: 2))), session > 0, part < 10000 {
            guard entries.count < 10000 else { throw RecorderBackgroundError.capacity }
            if let old = entries[name], old.2 != size { throw RecorderBackgroundError.invalid }
            if entries.contains(where: { $0.key != name && $0.value.0 == session && $0.value.1 == part }) { throw RecorderBackgroundError.invalid }
            entries[name] = (session, part, size)
          }
        }
        timeout(); return true
      }
      if op == 5, reading != nil {
        guard data.count == 7 else { throw RecorderBackgroundError.invalid }
        let size = data.suffix(4).reduce(0) { $0 << 8 | Int($1) }
        guard size == expected else { throw RecorderBackgroundError.invalid }; sizeSeen = true; timeout(); try finishRead(); return true
      }
      if op == 6, reading != nil {
        guard data.count == 3 else { throw RecorderBackgroundError.invalid }
        completionSeen = true; try finishRead(); return true
      }
    } catch { fail() }
    return false
  }
  private func finishRead() throws {
        guard received == expected, sizeSeen, completionSeen else { return }
        guard let name = reading, let value = entries[name], let path = partial else { throw RecorderBackgroundError.invalid }
        try output?.synchronize(); try output?.close(); output = nil; reading = nil; watchdog?.invalidate(); committing = true
        let capturedSn = sn, capturedPurpose = purpose
        work.async {
          do {
            let sha = try RecorderBackgroundFiles.sha(path)
            try RecorderBackgroundFiles.packets(path) { _ in }
            let dir = try RecorderBackgroundFiles.safeDirectory(self.transfer.root, ["recorder_long_audio_v1", capturedSn, "s\(value.0)"])
            let target = dir.appendingPathComponent("p\(value.1)-\(sha).ops")
            if FileManager.default.fileExists(atPath: target.path) {
              guard try RecorderBackgroundFiles.sha(target) == sha else { throw RecorderBackgroundError.invalid }
            } else { try FileManager.default.linkItem(at: path, to: target) }
            DispatchQueue.main.async {
              do {
                try self.record("source", value.0, extra: ["part": value.1, "size": value.2, "sha": sha, "source": "recorder_long_audio_v1/\(capturedSn)/s\(value.0)/p\(value.1)-\(sha).ops", "purpose": capturedPurpose])
                self.committing = false
                if let source = self.journal.last, source["purpose"] is String {
                  try self.prepareSource(source) { result in
                    do { try result.get(); try self.next() } catch { self.fail() }
                  }
                } else { try self.next() }
              } catch { self.committing = false; self.fail() }
            }
          } catch { DispatchQueue.main.async { self.committing = false; self.fail() } }
        }

  }
  private func data(_ data: Data) {
    guard reading != nil, !data.isEmpty, received + data.count <= expected else { fail(); return }
    do { guard let file = output else { throw RecorderBackgroundError.invalid }; try RecorderBackgroundFiles.write(file, data: data); received += data.count; timeout(); try finishRead() } catch { fail() }
  }
  private func next() throws {
    finishRelease(); if !owner || releasing || poisoned { return }
    let candidates = entries.sorted { a, b in a.value.0 == b.value.0 ? a.value.1 < b.value.1 : a.value.0 < b.value.0 }
    for (name, value) in candidates {
      guard stopped.contains(value.0) || activeSession == value.0 && closed[value.0]?.contains(value.1) == true else { continue }
      if let old = journal.last(where: { $0["kind"] as? String == "source" && ($0["session"] as? NSNumber)?.int64Value == value.0 && $0["part"] as? Int == value.1 && $0["sn"] as? String == sn }) {
        guard old["size"] as? Int == value.2 else { throw RecorderBackgroundError.invalid }
        continue
      }
      let dir = try RecorderBackgroundFiles.safeDirectory(transfer.root, ["recorder_long_audio_v1", sn, "s\(value.0)"])
      let available = (try FileManager.default.attributesOfFileSystem(forPath: dir.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
      guard available > Int64(value.2) + 32 * 1024 * 1024 else { throw RecorderBackgroundError.capacity }
      let path = dir.appendingPathComponent("native-\(UUID().uuidString).ops.partial")
      guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw RecorderBackgroundError.capacity }
      partial = path; output = try FileHandle(forWritingTo: path); reading = name; expected = value.2; received = 0; sizeSeen = false; completionSeen = false
      timeout(); var bytes = Data([0x11, 0x26]); bytes.append(Data(name.utf8)); send(bytes); return
    }
    for session in stopped {
      let names = candidates.filter { $0.value.0 == session }.map { $0.key + ":" + String($0.value.2) }
      if names.isEmpty { continue }
      let parts = candidates.filter { $0.value.0 == session }.map { $0.value.1 }.sorted()
      if parts != Array(0..<parts.count) { continue }
      if lastInventory[session] == names { tailCounts[session, default: 0] += 1 } else { tailCounts[session] = 1; lastInventory[session] = names }
      if tailCounts[session, default: 0] >= 5 {
        if !journal.contains(where: { $0["kind"] as? String == "finalized" && ($0["session"] as? NSNumber)?.int64Value == session }) {
          let stoppedAt = journal.last { $0["kind"] as? String == "stopped" && ($0["session"] as? NSNumber)?.int64Value == session && $0["sn"] as? String == sn }?["observed"]
          try record("finalized", session, extra: ["totalParts": parts.count, "observed": stoppedAt ?? ISO8601DateFormatter().string(from: Date())])
          flushManifests()
        }
      } else {
        tail?.invalidate(); tail = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.list() }
      }
    }
  }
}

#if canImport(Flutter)
final class RecorderBackgroundChannel {
  let receiver: RecorderBackgroundReceiver
  private let channel: FlutterMethodChannel
  private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
  private var lifecycleObserver: NSObjectProtocol?
  init(messenger: FlutterBinaryMessenger, receiver: RecorderBackgroundReceiver) {
    self.receiver = receiver
    channel = FlutterMethodChannel(name: "sunmate/recorder_background", binaryMessenger: messenger)
    lifecycleObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.backgroundTime == .invalid else { return }
      self.backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "SunMateRecorderHandoff") { [weak self] in
        guard let self = self else { return }
        // No protocol cancel is invented; release waits for a safe boundary.
        self.receiver.release { _ in self.endBackgroundTime() }
        self.endBackgroundTime()
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "unavailable", message: "后台传输未就绪", details: nil)); return }
      do {
        switch call.method {
        case "configure":
          try self.receiver.transfer.configure(call.arguments as? [String: Any] ?? [:]); result(true)
        case "acquire": try self.receiver.acquire(); self.endBackgroundTime(); result(true)
        case "release": self.receiver.release { clean in result(clean) }
        case "snapshot": result(self.receiver.snapshot().merging(["transfers": self.receiver.transfer.snapshot()]) { _, n in n })
        case "enqueue":
          try self.receiver.prepareSource(call.arguments as? [String: Any] ?? [:]) { outcome in
            switch outcome {
            case .success: result(true)
            case .failure: result(FlutterError(code: "source_invalid", message: "分段未完成校验，源音频保留。", details: nil))
            }
          }
        case "recover": self.receiver.transfer.recover(); result(true)
        case "pause":
          try self.receiver.transfer.pause(); self.receiver.release { clean in result(clean) }
        default: result(FlutterMethodNotImplemented)
        }
      } catch { result(FlutterError(code: "background_paused", message: "后台收段或上传已暂停；已有音频保留，请检查设置和连接。", details: nil)) }
    }
  }
  private func endBackgroundTime() {
    if backgroundTime != .invalid { UIApplication.shared.endBackgroundTask(backgroundTime); backgroundTime = .invalid }
  }
  deinit { if let observer = lifecycleObserver { NotificationCenter.default.removeObserver(observer) }; endBackgroundTime() }
}
#endif

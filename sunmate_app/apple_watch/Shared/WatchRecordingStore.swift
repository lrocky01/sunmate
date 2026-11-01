import Foundation
import CryptoKit

enum WatchRecordingError: Error { case disabled, invalid, conflict, capacity, unavailable }
enum WatchRecordingPurpose: String, Codable, CaseIterable { case voice, meeting, lifelog }

struct WatchRecordingPolicy: Codable, Equatable {
  var enabled = false
  var backgroundSync = false
  // Acquisition/transport are independent from ASR or sending a question.
  // This prototype never transmits service credentials or health information.
}

struct WatchAudioPart: Codable, Equatable {
  var source: String
  var session: Int64
  var purpose: WatchRecordingPurpose
  var part: Int
  var offsetFrames: Int64
  var frames: Int64
  var bytes: Int
  var sha256: String
  var started: Date
  var filename: String { "p\(part)-\(sha256).wav" }
  var id: String { "\(source):\(session):\(part):\(sha256)" }
  var duration: TimeInterval { Double(frames) / 16000 }
  func validate() throws {
    guard source.range(of: "^WATCH_[a-f0-9]{32}$", options: .regularExpression) != nil,
      (1577836800000...4102444800000).contains(session), (0..<10000).contains(part),
      offsetFrames >= 0, offsetFrames <= 16000 * 86400,
      frames > 0, frames <= 16000 * 120, bytes == 44 + Int(frames) * 2,
      sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      started.timeIntervalSince1970.isFinite else { throw WatchRecordingError.invalid }
  }
}

struct WatchRecordingManifest: Codable, Equatable {
  var source: String
  var session: Int64
  var purpose: WatchRecordingPurpose
  var started: Date
  var ended: Date?
  var interrupted = false
  var parts: [WatchAudioPart] = []
  var policy: WatchRecordingPolicy
  var id: String { "\(source):\(session)" }
  var complete: Bool { ended != nil && !interrupted && !parts.isEmpty }
  func validate() throws {
    guard parts.count <= 10000, policy.enabled else { throw WatchRecordingError.invalid }
    var offset: Int64 = 0
    for (i, p) in parts.enumerated() {
      try p.validate()
      guard p.source == source, p.session == session, p.purpose == purpose,
        p.started == started, p.part == i, p.offsetFrames == offset else { throw WatchRecordingError.invalid }
      offset += p.frames
    }
    if let ended = ended, ended < started { throw WatchRecordingError.invalid }
  }
}

/// Native mono PCM prototype: bounded two-minute WAV files, no codec dependency.
/// Phone and watch use exactly the same validation; no OPS/Opus/SN impersonation.
final class WatchRecordingStore {
  let root: URL
  private(set) var active: WatchRecordingManifest?
  private var pcm = Data()
  private let framesPerPart: Int
  private(set) var source: String
  private(set) var policy = WatchRecordingPolicy()
  private var receipts: Set<String> = []
  static let schema = "sunmate.watch.audio.v1"
  static let encoder: JSONEncoder = {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
  }()
  static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
  init(root: URL, framesPerPart: Int = 16000 * 120) throws {
    guard framesPerPart > 0, framesPerPart <= 16000 * 120 else { throw WatchRecordingError.invalid }
    self.root = root; self.framesPerPart = framesPerPart
    source = "WATCH_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try Self.directory(root)
    let settings = root.appendingPathComponent("settings.json")
    if FileManager.default.fileExists(atPath: settings.path) {
      let v = try Self.decoder.decode(Settings.self, from: Self.read(settings, limit: 4 * 1024 * 1024))
      guard v.source.range(of: "^WATCH_[a-f0-9]{32}$", options: .regularExpression) != nil else { throw WatchRecordingError.invalid }
      source = v.source; policy = v.policy; receipts = Set(v.receipts)
    } else { try persistSettings() }
    // Recovery records an interruption, never guesses that a crashed recording ended.
    for var item in try manifests() where item.ended == nil {
      active = item
      let capture = try sessionDirectory(item.source, item.session).appendingPathComponent("capture-p\(item.parts.count).pcm")
      if FileManager.default.fileExists(atPath: capture.path) {
        pcm = try Self.read(capture, limit: framesPerPart * 2)
        guard pcm.count % 2 == 0 else { throw WatchRecordingError.invalid }
        try closePart()
        item = active!
      }
      item.ended = max(Date(), item.started); item.interrupted = true; try save(item); active = nil; pcm = Data()
    }
  }
  private struct Settings: Codable { var source: String; var policy: WatchRecordingPolicy; var receipts: [String] }
  private func persistSettings() throws {
    try Self.atomic(Self.encoder.encode(Settings(source: source, policy: policy, receipts: receipts.sorted())), at: root.appendingPathComponent("settings.json"))
  }
  func setPolicy(_ value: WatchRecordingPolicy) throws {
    let old = policy; policy = value
    do { try persistSettings() } catch { policy = old; throw error }
  }
  static func directory(_ url: URL) throws {
    let f = FileManager.default
    if f.fileExists(atPath: url.path) {
      guard try f.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw WatchRecordingError.invalid }
    } else { try f.createDirectory(at: url, withIntermediateDirectories: false) }
    #if os(iOS) || os(watchOS)
    try f.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
  }
  static func read(_ file: URL, limit: Int) throws -> Data {
    let a = try FileManager.default.attributesOfItem(atPath: file.path)
    guard a[.type] as? FileAttributeType == .typeRegular,
      let n = a[.size] as? NSNumber, n.int64Value >= 0, n.int64Value <= limit else { throw WatchRecordingError.invalid }
    return try Data(contentsOf: file)
  }
  static func atomic(_ data: Data, at file: URL) throws {
    if FileManager.default.fileExists(atPath: file.path) {
      guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw WatchRecordingError.invalid }
    }
    try data.write(to: file, options: .atomic)
    #if os(iOS) || os(watchOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    #endif
  }
  private func sessionDirectory(_ source: String, _ session: Int64) throws -> URL {
    guard source.range(of: "^WATCH_[a-f0-9]{32}$", options: .regularExpression) != nil,
      (1577836800000...4102444800000).contains(session) else { throw WatchRecordingError.invalid }
    let origin = root.appendingPathComponent(source); try Self.directory(origin)
    let dir = origin.appendingPathComponent("s\(session)"); try Self.directory(dir); return dir
  }
  private func save(_ value: WatchRecordingManifest) throws {
    try value.validate()
    try Self.atomic(Self.encoder.encode(value), at: sessionDirectory(value.source, value.session).appendingPathComponent("manifest.json"))
  }
  func begin(_ purpose: WatchRecordingPurpose, now: Date = Date()) throws {
    guard policy.enabled else { throw WatchRecordingError.disabled }
    guard active == nil else { throw WatchRecordingError.conflict }
    guard now.timeIntervalSince1970.isFinite, (1577836800...4102444800).contains(now.timeIntervalSince1970) else { throw WatchRecordingError.invalid }
    let session = Int64(now.timeIntervalSince1970 * 1000)
    let dir = try sessionDirectory(source, session)
    guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { throw WatchRecordingError.conflict }
    let value = WatchRecordingManifest(source: source, session: session, purpose: purpose, started: now, policy: policy)
    try save(value); active = value; pcm.removeAll(keepingCapacity: true)
  }
  /// Caller serializes acquisition and stop. At most 120s of PCM stays in memory.
  func append(_ data: Data) throws {
    guard active != nil, data.count % 2 == 0 else { throw WatchRecordingError.invalid }
    var cursor = 0
    while cursor < data.count {
      let n = min(framesPerPart * 2 - pcm.count, data.count - cursor)
      let s = active!, capture = try sessionDirectory(s.source, s.session).appendingPathComponent("capture-p\(s.parts.count).pcm")
      if !FileManager.default.fileExists(atPath: capture.path) { try Self.atomic(Data(), at: capture) }
      let attrs = try FileManager.default.attributesOfItem(atPath: capture.path)
      guard attrs[.type] as? FileAttributeType == .typeRegular,
        (attrs[.size] as? NSNumber)?.intValue == pcm.count else { throw WatchRecordingError.conflict }
      guard #available(iOS 13.4, macOS 10.15.4, watchOS 7.0, *) else { throw WatchRecordingError.unavailable }
      let output = try FileHandle(forWritingTo: capture)
      do { try output.seekToEnd(); try output.write(contentsOf: data[cursor..<cursor+n]); try output.close() }
      catch { try? output.close(); throw error }
      pcm.append(data[cursor..<cursor+n]); cursor += n
      if pcm.count == framesPerPart * 2 { try closePart() }
    }
  }
  private func closePart() throws {
    guard var s = active, !pcm.isEmpty else { return }
    guard s.parts.count < 10000 else { throw WatchRecordingError.capacity }
    let available = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    guard available > Int64(pcm.count + 16 * 1024 * 1024) else { throw WatchRecordingError.capacity }
    let bytes = Self.wav(pcm)
    let part = WatchAudioPart(source: s.source, session: s.session, purpose: s.purpose, part: s.parts.count,
      offsetFrames: s.parts.reduce(0) { $0 + $1.frames }, frames: Int64(pcm.count / 2), bytes: bytes.count,
      sha256: Self.hash(bytes), started: s.started)
    let file = try sessionDirectory(s.source, s.session).appendingPathComponent(part.filename)
    if FileManager.default.fileExists(atPath: file.path) {
      guard try Self.read(file, limit: part.bytes) == bytes else { throw WatchRecordingError.conflict }
    } else { try Self.atomic(bytes, at: file) }
    s.parts.append(part); try save(s); active = s; pcm.removeAll(keepingCapacity: true)
  }
  func finish(interrupted: Bool = false, now: Date = Date()) throws -> WatchRecordingManifest {
    guard active != nil else { throw WatchRecordingError.conflict }
    try closePart(); var s = active!; s.ended = max(now, s.started); s.interrupted = interrupted
    try save(s); active = nil; return s
  }
  func manifests() throws -> [WatchRecordingManifest] {
    var result: [WatchRecordingManifest] = []
    let f = FileManager.default
    for origin in try f.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where origin.lastPathComponent.hasPrefix("WATCH_") {
      guard try f.attributesOfItem(atPath: origin.path)[.type] as? FileAttributeType == .typeDirectory else { throw WatchRecordingError.invalid }
      for dir in try f.contentsOfDirectory(at: origin, includingPropertiesForKeys: nil) where dir.lastPathComponent.hasPrefix("s") {
        guard try f.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType == .typeDirectory else { throw WatchRecordingError.invalid }
        let path = dir.appendingPathComponent("manifest.json")
        if !f.fileExists(atPath: path.path) { continue }
        let value = try Self.decoder.decode(WatchRecordingManifest.self, from: Self.read(path, limit: 4 * 1024 * 1024))
        try value.validate()
        guard value.source == origin.lastPathComponent, "s\(value.session)" == dir.lastPathComponent else { throw WatchRecordingError.invalid }
        result.append(value)
      }
    }
    return result.sorted { $0.session > $1.session }
  }
  func file(_ part: WatchAudioPart) throws -> URL {
    try part.validate(); let path = try sessionDirectory(part.source, part.session).appendingPathComponent(part.filename)
    let data = try Self.read(path, limit: 44 + 16000 * 120 * 2)
    guard data.count == part.bytes, Self.hash(data) == part.sha256 else { throw WatchRecordingError.invalid }
    try Self.validateWav(data, frames: part.frames); return path
  }
  /// WCSession's transport success is not an application-level durable receipt.
  func acknowledge(_ part: WatchAudioPart) throws {
    guard part.source == source else { throw WatchRecordingError.invalid }
    _ = try file(part); receipts.insert(part.id); try persistSettings()
  }
  func hasManifestReceipt(_ sha: String) -> Bool { receipts.contains("manifest:" + sha) }
  func acknowledgeManifest(_ sha: String) throws {
    guard sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      try manifests().contains(where: { value in
        guard value.source == source else { return false }
        return Self.hash(try Self.encoder.encode(value)) == sha
      }) else { throw WatchRecordingError.invalid }
    receipts.insert("manifest:" + sha); try persistSettings()
  }
  func pendingParts() throws -> [WatchAudioPart] {
    let values = try manifests().flatMap(\.parts)
    return values.filter { !receipts.contains($0.id) }
  }
  func importPart(_ part: WatchAudioPart, from temporary: URL) throws {
    try part.validate()
    let bytes = try Self.read(temporary, limit: 44 + 16000 * 120 * 2)
    guard bytes.count == part.bytes, Self.hash(bytes) == part.sha256 else { throw WatchRecordingError.invalid }
    try Self.validateWav(bytes, frames: part.frames)
    let dir = try sessionDirectory(part.source, part.session), target = dir.appendingPathComponent(part.filename)
    if FileManager.default.fileExists(atPath: target.path) {
      guard try Self.read(target, limit: part.bytes) == bytes else { throw WatchRecordingError.conflict }
    } else { try Self.atomic(bytes, at: target) }
  }
  func importManifest(_ value: WatchRecordingManifest) throws {
    try value.validate()
    for p in value.parts { _ = try file(p) }
    let path = try sessionDirectory(value.source, value.session).appendingPathComponent("manifest.json")
    if FileManager.default.fileExists(atPath: path.path) {
      let old = try Self.decoder.decode(WatchRecordingManifest.self, from: Self.read(path, limit: 4 * 1024 * 1024))
      guard value.source == old.source, value.session == old.session, value.purpose == old.purpose,
        value.parts.starts(with: old.parts), old.ended == nil || old == value else { throw WatchRecordingError.conflict }
    }
    try save(value)
  }
  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func wav(_ pcm: Data) -> Data {
    var data = wavHeader(frames: Int64(pcm.count / 2)); data.append(pcm); return data
  }
  static func wavHeader(frames: Int64) -> Data {
    let size = Int(frames) * 2
    var data = Data("RIFF".utf8)
    func le(_ n: UInt32, _ count: Int = 4) { for i in 0..<count { data.append(UInt8(truncatingIfNeeded: n >> (i * 8))) } }
    le(UInt32(size + 36)); data.append(Data("WAVEfmt ".utf8)); le(16); le(1, 2); le(1, 2)
    le(16000); le(32000); le(2, 2); le(16, 2); data.append(Data("data".utf8)); le(UInt32(size)); return data
  }
  static func validateWav(_ data: Data, frames: Int64) throws {
    guard frames > 0, frames <= 16000 * 86400,
      data.count == 44 + frames * 2,
      data.prefix(44) == wavHeader(frames: frames) else { throw WatchRecordingError.invalid }
  }
}

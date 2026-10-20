import Foundation
import AVFoundation
import CryptoKit
#if canImport(Flutter)
import Flutter
#endif

enum RecorderAudioError: Error, LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self { case .invalid(let message): return message }
  }
}

/// Offline conversion only. Validates our mono Ogg/Opus stream and decodes every
/// packet through Core Audio before publishing a PCM WAV file. No BLE or network.
@available(iOS 13.4, macOS 10.15.4, *)
final class RecorderAudioFiles {
  let supportRoot: URL
  private let folder = "recorder_long_audio_v1"
  init(supportRoot: URL) { self.supportRoot = supportRoot.resolvingSymlinksInPath().standardizedFileURL }

  func resolve(_ relative: String, suffix: String) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts.first == Substring(folder), relative.hasSuffix(suffix),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
        $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else {
      throw RecorderAudioError.invalid("录音路径无效")
    }
    let root = supportRoot.appendingPathComponent(folder, isDirectory: true)
    let url = supportRoot.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"),
      root.resolvingSymlinksInPath().path == root.path,
      url.resolvingSymlinksInPath().path == url.path else {
      throw RecorderAudioError.invalid("录音路径超出本机目录")
    }
    return url
  }

  func prepare(_ relative: String) throws -> [String: Any] {
    let source = try resolve(relative, suffix: ".ogg")
    let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
      throw RecorderAudioError.invalid("录音原档不是普通文件")
    }
    let directory = source.deletingLastPathComponent()
    let token = UUID().uuidString
    let packetFile = directory.appendingPathComponent("work-\(token).packets")
    let tableFile = directory.appendingPathComponent("work-\(token).table")
    let cafFile = directory.appendingPathComponent("work-\(token).caf")
    let waveFile = directory.appendingPathComponent("work-\(token).wav")
    // These are new converter work files, never the card original or Ogg archive.
    defer {
      for file in [packetFile, tableFile, cafFile, waveFile] { try? FileManager.default.removeItem(at: file) }
    }
    let input = OggInput(source: source, packetFile: packetFile, tableFile: tableFile)
    try input.parse()
    let hash = input.sourceDigest
    let target = directory.appendingPathComponent("playback-\(hash).wav")
    let manifest = directory.appendingPathComponent("playback-\(hash).json")
    let playableRelative = source.deletingLastPathComponent().path
      .dropFirst(supportRoot.path.count + 1) + "/" + target.lastPathComponent
    _ = try resolve(String(playableRelative), suffix: ".wav")
    let manifestRelative = String(playableRelative.dropLast(4)) + ".json"
    _ = try resolve(manifestRelative, suffix: ".json")
    if FileManager.default.fileExists(atPath: target.path) {
      // The current source digest names the only acceptable cached WAV.
      _ = try validatePlayback(String(playableRelative), expectedFrames: input.validFrames)
      let frames = input.validFrames
      return metadata(String(playableRelative), frames)
    }
    try input.makeCAF(cafFile)
    let compressed = try AVAudioFile(forReading: cafFile)
    guard compressed.processingFormat.channelCount == 1,
      compressed.processingFormat.sampleRate == 16000,
      compressed.length == input.validFrames else {
      throw RecorderAudioError.invalid("系统解码格式或时长不符合录音原档")
    }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    // AVAudioFile must close before syncing and publishing its WAV header.
    try decode(compressed, output: waveFile, settings: settings, expectedFrames: input.validFrames)
    let frames = try verifyWav(waveFile, expectedFrames: input.validFrames)
    let synced = try FileHandle(forWritingTo: waveFile)
    try synced.synchronize()
    try synced.close()
    // moveItem refuses to overwrite a file which appeared while decoding.
    let proof: [String: Any] = ["sourceSHA256": hash, "wavSHA256": try fileHash(waveFile),
      "frames": frames, "sampleRate": 16000]
    let proofData = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
    // Publishing the proof first means an interrupted rename is recoverable. A
    // WAV without a matching proof is never accepted as a completed conversion.
    if FileManager.default.fileExists(atPath: manifest.path) {
      let proofSize = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard proofSize > 0, proofSize <= 4096 else { throw RecorderAudioError.invalid("本地音频校验资料无效") }
      let oldProof = try Data(contentsOf: manifest)
      guard oldProof == proofData else { throw RecorderAudioError.invalid("本地音频校验资料冲突") }
    } else {
      try proofData.write(to: manifest, options: [.withoutOverwriting])
      let proofFile = try FileHandle(forWritingTo: manifest)
      try proofFile.synchronize(); try proofFile.close()
    }
    try FileManager.default.moveItem(at: waveFile, to: target)
    return metadata(String(playableRelative), frames)
  }

  /// Revalidate on the conversion queue immediately before every play request.
  /// A previously prepared path is not sufficient evidence after file mutation.
  func validatePlayback(_ relative: String, expectedFrames: Int64? = nil) throws -> URL {
    let target = try resolve(relative, suffix: ".wav")
    let proofPath = String(relative.dropLast(4)) + ".json"
    let proofURL = try resolve(proofPath, suffix: ".json")
    let info = try proofURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    let audioInfo = try target.resourceValues(forKeys: [.isRegularFileKey])
    guard info.isRegularFile == true, audioInfo.isRegularFile == true,
      let bytes = info.fileSize, bytes > 0, bytes <= 4096,
      let proof = try JSONSerialization.jsonObject(with: Data(contentsOf: proofURL)) as? [String: Any],
      let sourceHash = proof["sourceSHA256"] as? String,
      sourceHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      target.lastPathComponent == "playback-\(sourceHash).wav",
      let expectedHash = proof["wavSHA256"] as? String,
      expectedHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      let frameCount = proof["frames"] as? NSNumber,
      frameCount.int64Value > 0, frameCount.int64Value <= 2_000_000_000,
      expectedFrames == nil || frameCount.int64Value == expectedFrames,
      (proof["sampleRate"] as? NSNumber)?.intValue == 16000,
      try fileHash(target) == expectedHash else {
      throw RecorderAudioError.invalid("本地音频与解码校验资料不匹配")
    }
    _ = try verifyWav(target, expectedFrames: frameCount.int64Value)
    return target
  }

  private func fileHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while try autoreleasepool(invoking: {
      guard let bytes = try file.read(upToCount: 65536), !bytes.isEmpty else { return false }
      digest.update(data: bytes)
      return true
    }) {}
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func metadata(_ relative: String, _ frames: Int64) -> [String: Any] {
    ["relativePath": relative, "durationMs": frames * 1000 / 16000,
     "sampleRate": 16000, "frames": frames]
  }

  private func decode(_ input: AVAudioFile, output: URL,
                      settings: [String: Any], expectedFrames: Int64) throws {
    let wav = try AVAudioFile(forWriting: output, settings: settings,
      commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
      throw RecorderAudioError.invalid("无法创建音频解码缓冲")
    }
    var count: Int64 = 0
    while count < expectedFrames {
      try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, expectedFrames - count)))
      guard buffer.frameLength > 0 else { throw RecorderAudioError.invalid("录音解码提前结束") }
      try wav.write(from: buffer)
      count += Int64(buffer.frameLength)
    }
    guard count == expectedFrames else {
      throw RecorderAudioError.invalid("解码样本数量不匹配")
    }
  }

  private func verifyWav(_ url: URL, expectedFrames: Int64) throws -> Int64 {
    let verified = try AVAudioFile(forReading: url)
    guard verified.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
      verified.fileFormat.channelCount == 1, verified.fileFormat.sampleRate == 16000,
      verified.length == expectedFrames,
      let buffer = AVAudioPCMBuffer(pcmFormat: verified.processingFormat, frameCapacity: 8192) else {
      throw RecorderAudioError.invalid("本地音频校验失败")
    }
    var frames: Int64 = 0
    while frames < expectedFrames {
      try verified.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, expectedFrames - frames)))
      guard buffer.frameLength > 0 else { throw RecorderAudioError.invalid("本地音频读取提前结束") }
      frames += Int64(buffer.frameLength)
    }
    guard frames == expectedFrames else { throw RecorderAudioError.invalid("本地音频不完整") }
    return frames
  }
}

@available(iOS 13.4, macOS 10.15.4, *)
private final class OggInput {
  let source: URL
  let packetFile: URL
  let tableFile: URL
  private var packetCount: UInt64 = 0
  private var encodedBytes: UInt64 = 0
  private var tableBytes: UInt64 = 0
  private var preSkip: UInt16 = 0
  private var bandwidth: UInt32 = 0
  private var totalFrames: Int64 = 0
  private(set) var validFrames: Int64 = 0
  private(set) var sourceDigest = ""
  private var digest = SHA256()
  init(source: URL, packetFile: URL, tableFile: URL) {
    self.source = source; self.packetFile = packetFile; self.tableFile = tableFile
  }

  func parse() throws {
    let input = try FileHandle(forReadingFrom: source)
    FileManager.default.createFile(atPath: packetFile.path, contents: nil)
    let output = try FileHandle(forWritingTo: packetFile)
    FileManager.default.createFile(atPath: tableFile.path, contents: nil)
    let table = try FileHandle(forWritingTo: tableFile)
    defer { try? input.close(); try? output.close(); try? table.close() }
    var serial: UInt32?
    var sequence: UInt32 = 0
    var phase = 0
    var pending = Data()
    var ended = false
    var previousGranule: UInt64 = 0
    while true {
      var hasPage = false
      try autoreleasepool {
        guard let header = try read(input, count: 27, allowEOF: true) else { return }
        hasPage = true
        guard !ended, header.prefix(4) == Data("OggS".utf8), header[4] == 0,
          header[5] & 0xf8 == 0, header.u32(18) == sequence else {
          throw RecorderAudioError.invalid("Ogg 分页或顺序无效")
        }
        let flags = header[5]
        if sequence == 0 {
          guard flags == 2 else { throw RecorderAudioError.invalid("缺少 Ogg 起始页") }
          serial = header.u32(14)
        } else if flags & 2 != 0 {
          throw RecorderAudioError.invalid("不接受多个 Ogg 音轨")
        }
        guard serial == header.u32(14), (flags & 1 != 0) == !pending.isEmpty else {
          throw RecorderAudioError.invalid("Ogg 音轨或续页不匹配")
        }
        sequence &+= 1
        let laces = try read(input, count: Int(header[26]))!
        let body = try read(input, count: laces.reduce(0) { $0 + Int($1) })!
        let page = header + laces + body
        guard crc(page) == header.u32(22) else { throw RecorderAudioError.invalid("Ogg CRC 校验失败") }
        digest.update(data: page)
        var offset = 0
        for lace in laces {
          let length = Int(lace)
          pending.append(body.subdata(in: offset ..< offset + length)); offset += length
          guard pending.count <= 131072 else { throw RecorderAudioError.invalid("Ogg 音频包超限") }
          if lace == 255 { continue }
          switch phase {
          case 0:
            guard pending.count == 19, pending.prefix(8) == Data("OpusHead".utf8),
              pending[8] == 1, pending[9] == 1, pending[18] == 0,
              pending.u32(12) == 16000, pending.u16(16) == 0 else {
              throw RecorderAudioError.invalid("仅支持卡片单声道 16k Opus 原档")
            }
            preSkip = pending.u16(10)
            guard preSkip % 3 == 0 else { throw RecorderAudioError.invalid("Opus 预跳过量无效") }
            phase = 1
          case 1:
            guard pending.count >= 16, pending.prefix(8) == Data("OpusTags".utf8) else {
              throw RecorderAudioError.invalid("缺少 Opus 标签页")
            }
            phase = 2
          default:
            guard !pending.isEmpty, pending.count <= 65024, pending[0] & 4 == 0 else {
              throw RecorderAudioError.invalid("Opus 包不是卡片单声道格式")
            }
            if packetCount == 0 {
              let config = Int(pending[0] >> 3)
              bandwidth = config < 12 ? UInt32(1101 + config / 4) :
                config < 16 ? UInt32(1104 + (config - 12) / 2) :
                  config < 20 ? 1101 : config < 24 ? 1103 : config < 28 ? 1104 : 1105
            }
            let frames = try packetSamples(pending) / 3
            try output.write(contentsOf: pending)
            var record = Data()
            for original in [pending.count, frames] {
              var value = original; var bytes = [UInt8(value & 127)]; value >>= 7
              while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
              record.append(contentsOf: bytes)
            }
            try table.write(contentsOf: record)
            packetCount += 1; encodedBytes += UInt64(pending.count); tableBytes += UInt64(record.count)
            totalFrames += Int64(frames)
            guard totalFrames <= 2_000_000_000 else { throw RecorderAudioError.invalid("录音超出 WAV 容量") }
          }
          pending.removeAll(keepingCapacity: true)
        }
        let granule = header.u64(6)
        if granule != UInt64.max {
          guard granule >= previousGranule, granule <= UInt64(totalFrames * 3) else {
            throw RecorderAudioError.invalid("Ogg 采样位置无效")
          }
          previousGranule = granule
        }
        if flags & 4 != 0 {
          guard pending.isEmpty, phase == 2, packetCount > 0, granule != UInt64.max,
            granule > UInt64(preSkip), granule % 3 == 0 else {
            throw RecorderAudioError.invalid("Ogg 尾页不完整")
          }
          validFrames = Int64(granule - UInt64(preSkip)) / 3
          ended = true
        }
      }
      if !hasPage { break }
    }
    guard ended, validFrames > 0 else { throw RecorderAudioError.invalid("录音缺少完整结束页") }
    try output.synchronize(); try table.synchronize()
    sourceDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func makeCAF(_ destination: URL) throws {
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    let packets = try FileHandle(forReadingFrom: packetFile)
    let records = try FileHandle(forReadingFrom: tableFile)
    defer { try? output.close(); try? packets.close(); try? records.close() }
    try output.write(contentsOf: Data([0x63,0x61,0x66,0x66,0,1,0,0]))
    var desc = Data(); desc.be(Double(16000).bitPattern); desc.append(Data("opus".utf8))
    for value: UInt32 in [0,0,0,1,0] { desc.be(value) }
    try chunk(output, "desc", desc)
    var cookie = Data()
    for value: UInt32 in [2049,16000,0,bandwidth,1,1,0] { cookie.be(value) }
    try chunk(output, "kuki", cookie)
    var dataHeader = Data("data".utf8)
    dataHeader.be(encodedBytes + 4); dataHeader.be(UInt32(0))
    try output.write(contentsOf: dataHeader)
    try copyChunks(packets, to: output)
    var tableHeader = Data("pakt".utf8); tableHeader.be(tableBytes + 24)
    tableHeader.be(packetCount); tableHeader.be(UInt64(validFrames))
    tableHeader.be(UInt32(preSkip / 3)); tableHeader.be(UInt32(totalFrames - validFrames - Int64(preSkip / 3)))
    try output.write(contentsOf: tableHeader)
    try copyChunks(records, to: output)
    try output.synchronize()
  }

  private func copyChunks(_ input: FileHandle, to output: FileHandle) throws {
    while try autoreleasepool(invoking: {
      guard let data = try input.read(upToCount: 65536), !data.isEmpty else { return false }
      try output.write(contentsOf: data)
      return true
    }) {}
  }

  private func packetSamples(_ bytes: Data) throws -> Int {
    let config = Int(bytes[0] >> 3)
    let perFrame = config < 12 ? [480,960,1920,2880][config % 4] :
      config < 16 ? [480,960][config % 2] : [120,240,480,960][config % 4]
    let code = bytes[0] & 3
    let count: Int
    switch code {
    case 0: count = 1
    case 1,2: count = 2
    default:
      guard bytes.count >= 2 else { throw RecorderAudioError.invalid("Opus 包头不完整") }
      count = Int(bytes[1] & 63)
    }
    guard count > 0, perFrame * count <= 5760 else { throw RecorderAudioError.invalid("Opus 时长无效") }
    return perFrame * count
  }

  private func read(_ file: FileHandle, count: Int, allowEOF: Bool = false) throws -> Data? {
    if count == 0 { return Data() }
    var data = Data()
    while data.count < count {
      guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else {
        if data.isEmpty && allowEOF { return nil }
        throw RecorderAudioError.invalid("Ogg 文件截断")
      }
      data.append(part)
    }
    return data
  }

  private func chunk(_ output: FileHandle, _ name: String, _ content: Data) throws {
    var header = Data(name.utf8); header.be(UInt64(content.count))
    try output.write(contentsOf: header); try output.write(contentsOf: content)
  }
  private func crc(_ page: Data) -> UInt32 {
    var result: UInt32 = 0
    for (index, byte) in page.enumerated() {
      result ^= UInt32((22..<26).contains(index) ? 0 : byte) << 24
      for _ in 0..<8 { result = (result << 1) ^ ((result & 0x80000000 != 0) ? 0x04c11db7 : 0) }
    }
    return result
  }
}

private extension Data {
  func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index+1]) << 8 }
  func u32(_ index: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index+$1]) << ($1*8) }
  }
  func u64(_ index: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[index+$1]) << ($1*8) }
  }
  mutating func be<T: FixedWidthInteger>(_ value: T) {
    var copy = value.bigEndian; Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
  }
}

#if canImport(Flutter)
final class RecorderLocalAudioChannel {
  private let channel: FlutterMethodChannel
  private let conversion = DispatchQueue(label: "sunmate.recorder-audio-conversion")
  private var player: AVAudioPlayer?
  private var playingPath: String?
  private var playbackRequest: UInt64 = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "sunmate/recorder_local_audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard #available(iOS 13.4, *) else {
      result(FlutterError(code: "unsupported_audio", message: "当前系统不支持离线录音转换，请使用 iOS 13.4 或更新版本", details: nil))
      return
    }
    let files = RecorderAudioFiles(supportRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    if call.method == "prepare" {
      guard let args = call.arguments as? [String: Any], let path = args["relativePath"] as? String else {
        result(FlutterError(code: "invalid_path", message: "缺少录音路径", details: nil)); return
      }
      conversion.async { [files] in
        do {
          let prepared = try files.prepare(path)
          DispatchQueue.main.async { result(prepared) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "decode_failed", message: "本地录音解码或校验失败，原档已保留", details: nil)) }
        }
      }
      return
    }
    if call.method == "play" {
      guard let args = call.arguments as? [String: Any], let path = args["relativePath"] as? String else {
        result(FlutterError(code: "invalid_path", message: "缺少播放路径", details: nil)); return
      }
      playbackRequest &+= 1
      let request = playbackRequest
      conversion.async { [weak self, files] in
        do {
          let file = try files.validatePlayback(path)
          DispatchQueue.main.async { [weak self] in
            guard let owner = self, owner.playbackRequest == request else {
              result(FlutterError(code: "playback_cancelled", message: "播放请求已取消", details: nil)); return
            }
            do {
              try owner.startPlayer(file: file, relative: path)
              result(nil)
            } catch {
              result(FlutterError(code: "playback_failed", message: "无法播放本地录音，原档已保留", details: nil))
            }
          }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "playback_failed", message: "本地录音完整性校验失败，原档已保留", details: nil)) }
        }
      }
      return
    }
    switch call.method {
      case "pause": playbackRequest &+= 1; player?.pause(); result(nil)
      case "stop":
        playbackRequest &+= 1
        player?.stop(); player?.currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        result(nil)
      case "state":
        result(["isPlaying": player?.isPlaying ?? false,
                "positionMs": Int((player?.currentTime ?? 0) * 1000),
                "durationMs": Int((player?.duration ?? 0) * 1000),
                "relativePath": playingPath as Any? ?? NSNull()])
      default: result(FlutterMethodNotImplemented)
    }
  }

  private func startPlayer(file: URL, relative: String) throws {
    if playingPath != relative || player == nil {
      let next = try AVAudioPlayer(contentsOf: file)
      guard next.prepareToPlay(), next.duration > 0 else { throw RecorderAudioError.invalid("音频无法播放") }
      player?.stop(); player = next; playingPath = relative
    }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try AVAudioSession.sharedInstance().setActive(true)
    guard player?.play() == true else { throw RecorderAudioError.invalid("播放未启动") }
  }
}
#endif

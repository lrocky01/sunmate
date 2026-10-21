import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

enum RecorderBackgroundError: Error { case invalid, capacity, busy, unauthorized }

/// File-only utilities shared by the native receiver and local regression harness.
/// Reads one bounded packet at a time; a full day of audio never enters memory.
enum RecorderBackgroundFiles {
  static func sha(_ file: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
    var digest = SHA256()
    while let data = try input.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func safeDirectory(_ root: URL, _ components: [String]) throws -> URL {
    var result = root
    for component in components {
      guard component.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw RecorderBackgroundError.invalid }
      result.appendPathComponent(component, isDirectory: true)
      if FileManager.default.fileExists(atPath: result.path) {
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw RecorderBackgroundError.invalid }
      } else {
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
      }
      #if os(iOS)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: result.path)
      #endif
    }
    return result
  }
  static func samples(_ p: Data) throws -> Int64 {
    guard let toc = p.first, toc & 4 == 0 else { throw RecorderBackgroundError.invalid }
    let config = Int(toc >> 3)
    let perFrame = config >= 16 ? 120 << (config & 3) : config >= 12 ? 480 << (config & 1) : config & 3 == 3 ? 2880 : 480 << (config & 3)
    let code = toc & 3
    let count = code == 0 ? 1 : code < 3 ? 2 : p.count > 1 ? Int(p[1] & 63) : 0
    guard count > 0, count <= 48, perFrame * count <= 5760 else { throw RecorderBackgroundError.invalid }
    return Int64(perFrame * count)
  }
  static func packets(_ file: URL, _ consume: (Data) throws -> Void) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          let size = attrs[.size] as? NSNumber, size.int64Value > 8, size.int64Value <= 268435456 else { throw RecorderBackgroundError.invalid }
    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
    var total: Int64 = 0
    while total < size.int64Value {
      guard let header = try input.read(upToCount: 8), header.count == 8 else { throw RecorderBackgroundError.invalid }
      let n = header.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
      guard n > 0, n <= 65536, header.suffix(4).allSatisfy({ $0 == 0 }),
            let data = try input.read(upToCount: n), data.count == n else { throw RecorderBackgroundError.invalid }
      _ = try samples(data)
      try consume(data)
      total += Int64(8 + n)
    }
    guard total == size.int64Value else { throw RecorderBackgroundError.invalid }
  }
  static func mux(_ file: URL, to output: URL, serial: UInt32, context: URL? = nil) throws -> (Int64, Int64) {
    var tail: [Data] = [], lead: Int64 = 0
    if let previous = context {
      try packets(previous) { data in
        tail.append(data); lead += try samples(data)
        while tail.count > 1, lead - (try samples(tail[0])) >= 48000 { lead -= try samples(tail.removeFirst()) }
      }
    }
    guard lead <= 65535, !FileManager.default.fileExists(atPath: output.path),
          FileManager.default.createFile(atPath: output.path, contents: nil) else { throw RecorderBackgroundError.invalid }
    let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
    var sequence: UInt32 = 0, granule: Int64 = 0
    func page(_ data: Data, flags: UInt8, samples: Int64, empty: Bool = false) throws {
      let segments = empty ? 0 : data.count / 255 + 1
      guard segments <= 255 else { throw RecorderBackgroundError.invalid }
      var bytes = [UInt8](repeating: 0, count: 27 + segments)
      bytes.replaceSubrange(0..<4, with: Array("OggS".utf8)); bytes[5] = flags
      for i in 0..<8 { bytes[6+i] = UInt8(truncatingIfNeeded: samples >> (i * 8)) }
      for i in 0..<4 { bytes[14+i] = UInt8(truncatingIfNeeded: serial >> (i * 8)); bytes[18+i] = UInt8(truncatingIfNeeded: sequence >> (i * 8)) }
      sequence += 1; bytes[26] = UInt8(segments)
      for i in 0..<segments { bytes[27+i] = UInt8(i == segments-1 ? data.count % 255 : 255) }
      bytes.append(contentsOf: data)
      var crc: UInt32 = 0
      for byte in bytes {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x80000000 != 0 ? 0x04c11db7 : 0) }
      }
      for i in 0..<4 { bytes[22+i] = UInt8(truncatingIfNeeded: crc >> (i * 8)) }
      try handle.write(contentsOf: Data(bytes))
    }
    var head = Data("OpusHead".utf8)
    // ASR container includes decoder context; result timestamps trim lead48 later.
    head.append(contentsOf: [1, 1, 0, 0, 0x80, 0x3e, 0, 0, 0, 0, 0])
    try page(head, flags: 2, samples: 0)
    let vendor = Array("SunMate Background Recorder".utf8)
    var tags = Data("OpusTags".utf8)
    tags.append(contentsOf: [UInt8(vendor.count), 0, 0, 0]); tags.append(contentsOf: vendor); tags.append(contentsOf: [0,0,0,0])
    try page(tags, flags: 0, samples: 0)
    for data in tail { granule += try samples(data); try page(data, flags: 0, samples: granule) }
    var count: Int64 = 0
    try packets(file) { data in
      let duration = try samples(data); count += duration; granule += duration
      try page(data, flags: 0, samples: granule)
    }
    try page(Data(), flags: 4, samples: granule, empty: true)
    try handle.synchronize()
    return (count, lead)
  }
}

import Foundation
#if canImport(Flutter)
import Flutter
import AVFoundation

final class AppleWatchChannel {
  private let channel: FlutterMethodChannel
  private let link: WatchRecordingLink
  private let health = WatchHealthReadOnly()
  private var player: AVAudioPlayer?
  init(messenger: FlutterBinaryMessenger, root: URL) throws {
    link = try WatchRecordingLink(root: root.appendingPathComponent("sunmate_watch_audio_v1"))
    channel = FlutterMethodChannel(name: "sunmate/apple_watch", binaryMessenger: messenger)
    link.changed = { [weak self] in self?.channel.invokeMethod("changed", arguments: nil) }
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "healthConfigure" {
      guard let enabled = args["enabled"] as? Bool, let types = args["types"] as? [String], Set(args.keys) == ["enabled", "types"] else { result(false); return }
      health.configure(enabled: enabled, types: Set(types)) { ok in result(ok) }; return
    }
    if call.method == "healthSnapshot" { health.snapshot { result($0) }; return }
    if call.method == "configure" {
      guard let enabled = args["enabled"] as? Bool, let sync = args["backgroundSync"] as? Bool, Set(args.keys) == ["enabled", "backgroundSync"] else { result(false); return }
      link.setPolicy(WatchRecordingPolicy(enabled: enabled, backgroundSync: sync)) { result($0) }; return
    }
    if call.method == "stopPlayback" { player?.stop(); player = nil; result(true); return }
    link.work.async {
      do {
        switch call.method {
        case "snapshot":
          let v = try self.link.snapshot(); DispatchQueue.main.async { result(v) }
        case "readPart", "playPart":
          guard let identity = args["id"] as? String,
            let part = try self.link.store.manifests().flatMap(\.parts).first(where: { $0.id == identity }) else { throw WatchRecordingError.invalid }
          let file = try self.link.store.file(part)
          if call.method == "readPart" {
            let data = try WatchRecordingStore.read(file, limit: 44 + 16000 * 120 * 2)
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
          } else {
            DispatchQueue.main.async {
              do { self.player?.stop(); self.player = try AVAudioPlayer(contentsOf: file); guard self.player!.play() else { throw WatchRecordingError.invalid }; result(true) }
              catch { result(FlutterError(code: "watch_audio", message: "音频未能播放，源文件保留。", details: nil)) }
            }
          }
        default: DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
      } catch { DispatchQueue.main.async { result(FlutterError(code: "watch_source", message: "手表文件或连接尚未就绪；请检查设置后重试。", details: nil)) } }
    }
  }
}
#endif

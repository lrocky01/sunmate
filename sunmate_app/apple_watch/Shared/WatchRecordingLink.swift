#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// One serial owner for the store and WCSession; no custom BLE pairing or secrets.
final class WatchRecordingLink: NSObject, WCSessionDelegate {
  let store: WatchRecordingStore
  let work = DispatchQueue(label: "sunmate.watch.recordings")
  var changed: (() -> Void)?
  var status: [String: Any] = [:]
  private var pendingManifests: [String: WatchRecordingManifest] = [:]
  private(set) var enabled = false
  private let wc: WCSession?
  init(root: URL) throws {
    store = try WatchRecordingStore(root: root)
    enabled = store.policy.enabled
    wc = WCSession.isSupported() ? WCSession.default : nil
    super.init()
    wc?.delegate = self
    // Activation alone never starts a recording or transfers a saved recording.
    wc?.activate()
  }
  func setPolicy(_ policy: WatchRecordingPolicy, completion: @escaping (Bool) -> Void) {
    work.async {
      do {
        try self.store.setPolicy(policy); self.enabled = policy.enabled
        self.notify(); DispatchQueue.main.async { completion(true) }
      } catch { DispatchQueue.main.async { completion(false) } }
    }
  }
  var reachable: Bool { wc?.activationState == .activated && wc?.isReachable == true }
  func snapshot() throws -> [String: Any] {
    let data = try WatchRecordingStore.encoder.encode(store.manifests())
    var result: [String: Any] = ["supported": wc != nil, "enabled": store.policy.enabled,
      "backgroundSync": store.policy.backgroundSync, "reachable": reachable,
      "source": store.source, "sessions": try JSONSerialization.jsonObject(with: data), "status": status]
    #if os(iOS)
    result["paired"] = wc?.isPaired ?? false
    result["watchAppInstalled"] = wc?.isWatchAppInstalled ?? false
    #endif
    return result
  }
  func notify() { DispatchQueue.main.async { self.changed?() } }
  func sync(manual: Bool) {
    work.async {
      guard self.enabled, manual || self.store.policy.backgroundSync,
        let wc = self.wc, wc.activationState == .activated else { return }
      do {
        let queued = Set(wc.outstandingFileTransfers.compactMap { $0.file.metadata?["identity"] as? String })
        for part in try self.store.pendingParts() where !queued.contains(part.id) {
          let data = try WatchRecordingStore.encoder.encode(part)
          wc.transferFile(try self.store.file(part), metadata: ["schema": WatchRecordingStore.schema, "kind": "part", "identity": part.id, "part": data])
        }
        // Immutable snapshots: a file already queued is never mutated underneath WC.
        let dir = self.store.root.appendingPathComponent("manifests"); try WatchRecordingStore.directory(dir)
        for value in try self.store.manifests() where value.ended != nil {
          let data = try WatchRecordingStore.encoder.encode(value), sha = WatchRecordingStore.hash(data)
          let identity = "manifest:" + sha
          if queued.contains(identity) || self.store.hasManifestReceipt(sha) { continue }
          let path = dir.appendingPathComponent(sha + ".json")
          if !FileManager.default.fileExists(atPath: path.path) { try WatchRecordingStore.atomic(data, at: path) }
          wc.transferFile(path, metadata: ["schema": WatchRecordingStore.schema, "kind": "manifest", "identity": identity, "sha": sha])
        }
        self.status = ["state": "queued", "message": "等待系统传输；原音频保留。"]
      } catch { self.status = ["state": "failed", "message": "同步准备未完成，请检查空间并重试。"] }
      self.notify()
    }
  }
  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    work.async {
      self.status = ["state": error == nil ? "ready" : "unavailable"]
      if error == nil && self.enabled { try? self.reconcile() }
      self.notify()
    }
    if error == nil { sync(manual: false) }
  }
  func sessionReachabilityDidChange(_ session: WCSession) { notify() }
  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    // The OS temporary file must be copied before returning from this callback.
    work.sync {
      guard enabled, let m = file.metadata, m["schema"] as? String == WatchRecordingStore.schema else { return }
      do {
        if m["kind"] as? String == "part", let data = m["part"] as? Data {
          let part = try WatchRecordingStore.decoder.decode(WatchAudioPart.self, from: data)
          try store.importPart(part, from: file.fileURL)
          session.transferUserInfo(["schema": WatchRecordingStore.schema, "ack": data])
        } else if m["kind"] as? String == "manifest", let sha = m["sha"] as? String {
          let data = try WatchRecordingStore.read(file.fileURL, limit: 4 * 1024 * 1024)
          guard WatchRecordingStore.hash(data) == sha else { throw WatchRecordingError.invalid }
          let manifest = try WatchRecordingStore.decoder.decode(WatchRecordingManifest.self, from: data)
          try manifest.validate()
          let dir = store.root.appendingPathComponent("pending"); try WatchRecordingStore.directory(dir)
          try WatchRecordingStore.atomic(data, at: dir.appendingPathComponent(sha + ".json"))
          pendingManifests[manifest.id] = manifest
        } else { throw WatchRecordingError.invalid }
        try reconcile()
        status = ["state": "received", "message": "手机已安全保存收到的文件，尚不代表服务器已同步。"]
      } catch { status = ["state": "failed", "message": "收到的文件未通过校验，原音频保留。"] }
      notify()
    }
  }
  private func reconcile() throws {
    let pending = store.root.appendingPathComponent("pending")
    if FileManager.default.fileExists(atPath: pending.path) {
      try WatchRecordingStore.directory(pending)
      for file in try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
        let value = try WatchRecordingStore.decoder.decode(WatchRecordingManifest.self, from: WatchRecordingStore.read(file, limit: 4 * 1024 * 1024))
        let old = pendingManifests[value.id]
        if old == nil || value.parts.count > old!.parts.count || value.parts.count == old!.parts.count && old!.ended == nil && value.ended != nil {
          pendingManifests[value.id] = value
        }
      }
    }
    for value in pendingManifests.values {
      do {
        try store.importManifest(value)
        let sha = WatchRecordingStore.hash(try WatchRecordingStore.encoder.encode(value))
        if wc?.activationState == .activated {
          wc?.transferUserInfo(["schema": WatchRecordingStore.schema, "manifestAck": sha])
        }
      } catch { continue } // Out-of-order files remain pending on disk.
    }
  }
  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    work.async {
      guard userInfo["schema"] as? String == WatchRecordingStore.schema else { return }
      do {
        if let data = userInfo["ack"] as? Data {
          let part = try WatchRecordingStore.decoder.decode(WatchAudioPart.self, from: data)
          try self.store.acknowledge(part)
        } else if let sha = userInfo["manifestAck"] as? String { try self.store.acknowledgeManifest(sha) }
        self.notify()
      } catch { self.status = ["state": "receipt_invalid"] }
    }
  }
  func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    // Do not mark delivered here; only the counterpart's durable receipt can do that.
    if error != nil { work.async { self.status = ["state": "retry", "message": "系统传输未完成，稍后可重试。 "]; self.notify() } }
  }
  #if os(iOS)
  func sessionDidBecomeInactive(_ session: WCSession) { notify() }
  func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  #endif
}
#endif

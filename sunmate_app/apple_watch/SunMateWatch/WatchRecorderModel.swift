import Foundation
import SwiftUI
import AVFoundation
import WatchKit

@MainActor final class WatchRecorderModel: ObservableObject {
  @Published var enabled = false
  @Published var backgroundSync = false
  @Published var recording = false
  @Published var busy = false
  @Published var purpose: WatchRecordingPurpose = .voice
  @Published var message = "先开启录音；音频保存在手表，转写和问答需要手机及私有节点。"
  @Published var elapsed: TimeInterval = 0
  @Published var pending = 0
  let link: WatchRecordingLink?
  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var interrupted: NSObjectProtocol?
  private var started: Date?
  private var holding = false, holdStart = false
  init() {
    do {
      let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      link = try WatchRecordingLink(root: base.appendingPathComponent("sunmate_watch_audio_v1"))
    } catch { link = nil }
    link?.changed = { [weak self] in Task { @MainActor in self?.refresh() } }
    interrupted = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
        Task { @MainActor in self?.stop(interrupted: true) }
      }
    }
    refresh()
  }
  func refresh() {
    guard let link else { message = "本机录音存储未就绪，请检查空间后重开。"; return }
    link.work.async {
      let policy = link.store.policy, count = (try? link.store.pendingParts().count) ?? 0
      DispatchQueue.main.async { self.enabled = policy.enabled; self.backgroundSync = policy.backgroundSync; self.pending = count }
    }
  }
  func setEnabled(_ value: Bool) {
    guard !recording, let link else { return }
    link.setPolicy(WatchRecordingPolicy(enabled: value, backgroundSync: backgroundSync)) { ok in
      if ok { self.enabled = value } else { self.message = "设置未保存，请重试。" }
    }
  }
  func setSync(_ value: Bool) {
    guard let link else { return }
    link.setPolicy(WatchRecordingPolicy(enabled: enabled, backgroundSync: value)) { ok in
      if ok { self.backgroundSync = value } else { self.message = "同步设置未保存。" }
    }
  }
  func start() {
    guard enabled, !recording, !busy, let link else { return }
    busy = true
    AVAudioSession.sharedInstance().requestRecordPermission { allowed in
      Task { @MainActor in
        guard allowed else { self.busy = false; self.message = "麦克风未获允许，请到系统设置开启。"; return }
        if self.holdStart && !self.holding { self.holdStart = false; self.busy = false; return }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.record, mode: .default)
          try session.setActive(true)
          let engine = AVAudioEngine(), input = engine.inputNode
          let source = input.outputFormat(forBus: 0)
          guard source.sampleRate > 0, source.channelCount > 0,
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: format) else { throw WatchRecordingError.unavailable }
          converter.primeMethod = .none
          let purpose = self.purpose
          try link.work.sync { try link.store.begin(purpose) }
          self.converter = converter; self.engine = engine; self.started = Date()
          input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            // Copy tap memory before leaving the audio callback.
            guard let copy = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: buffer.frameLength) else {
              Task { @MainActor in self.stop(interrupted: true) }; return
            }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
              if let a = src[i].mData, let b = dst[i].mData { memcpy(b, a, Int(src[i].mDataByteSize)); dst[i].mDataByteSize = src[i].mDataByteSize }
            }
            link.work.async {
              guard link.store.active != nil else { return }
              do {
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / source.sampleRate) + 64)
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw WatchRecordingError.capacity }
                var supplied = false, error: NSError?
                let result = converter.convert(to: output, error: &error) { _, status in
                  if supplied { status.pointee = .noDataNow; return nil }
                  supplied = true; status.pointee = .haveData; return copy
                }
                guard result != .error, error == nil, let samples = output.int16ChannelData else { throw WatchRecordingError.invalid }
                let parts = link.store.active?.parts.count ?? 0
                if output.frameLength > 0 { try link.store.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2)) }
                if (link.store.active?.parts.count ?? 0) > parts { link.sync(manual: false) }
                DispatchQueue.main.async {
                  self.elapsed = Date().timeIntervalSince(self.started ?? Date())
                  if purpose == .voice && self.elapsed >= 120 { self.stop() }
                }
              } catch { Task { @MainActor in self.stop(interrupted: true) } }
            }
          }
          try engine.start(); self.recording = true; self.busy = false; self.elapsed = 0
          self.message = "正在录音；熄屏不会主动停止。"; WKInterfaceDevice.current().play(.start)
        } catch {
          self.engine?.inputNode.removeTap(onBus: 0); self.engine?.stop(); self.engine = nil
          link.work.async { _ = try? link.store.finish(interrupted: true) }
          self.busy = false; self.message = "录音未能开始，已有音频保留。"
        }
      }
    }
  }
  func hold(_ value: Bool) {
    holding = value
    if value && !recording && !busy { holdStart = true; start() }
    if !value && recording { stop() }
  }
  func stop(interrupted: Bool = false) {
    guard recording, !busy, let link else { return }
    busy = true; holdStart = false; engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
    let converter = self.converter; self.converter = nil
    link.work.async {
      do {
        // Drain the converter once; all earlier tap work uses this same serial queue.
        if let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 2048) {
          var error: NSError?
          let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
          if status != .error, error == nil, output.frameLength > 0, let p = output.int16ChannelData {
            try link.store.append(Data(bytes: p[0], count: Int(output.frameLength) * 2))
          }
        }
        _ = try link.store.finish(interrupted: interrupted)
        DispatchQueue.main.async {
          self.recording = false; self.busy = false; self.started = nil
          self.message = interrupted ? "录音被中断，已完成片段保留。" : "音频已保存在手表，等待同步。"
          try? AVAudioSession.sharedInstance().setActive(false)
          WKInterfaceDevice.current().play(.stop); self.refresh(); link.sync(manual: false)
        }
      } catch { DispatchQueue.main.async { self.recording = false; self.busy = false; self.message = "音频封尾未完成，已有文件保留，请勿卸载App。" } }
    }
  }
}

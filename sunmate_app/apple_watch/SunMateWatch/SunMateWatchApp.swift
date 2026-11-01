import SwiftUI

@main struct SunMateWatchApp: App {
  @StateObject private var recorder = WatchRecorderModel()
  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("SunMate").font(.title2).bold()
          Toggle("启用录音", isOn: Binding(get: { recorder.enabled }, set: recorder.setEnabled)).disabled(recorder.recording || recorder.busy)
          Picker("录音用途", selection: $recorder.purpose) {
            Text("语音对讲").tag(WatchRecordingPurpose.voice)
            Text("会议").tag(WatchRecordingPurpose.meeting)
            Text("随身记录").tag(WatchRecordingPurpose.lifelog)
          }.disabled(recorder.recording || recorder.busy)
          if recorder.recording { Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit().font(.title) }
          if recorder.purpose == .voice {
            Text(recorder.recording ? "松开结束" : "按住说话")
              .frame(maxWidth: .infinity, minHeight: 44).background(.orange.opacity(0.2)).contentShape(Rectangle())
              .gesture(DragGesture(minimumDistance: 0).onChanged { _ in recorder.hold(true) }.onEnded { _ in recorder.hold(false) })
              .accessibilityLabel("按住说话，也可以使用下方开始和结束按钮")
              .disabled(!recorder.enabled)
          }
          Button(recorder.recording ? "结束并保存" : "开始录音") {
            if recorder.recording { recorder.stop() } else { recorder.start() }
          }.buttonStyle(.borderedProminent).tint(recorder.recording ? .red : .orange).disabled(!recorder.enabled || recorder.busy)
          Text(recorder.message).font(.footnote)
          Toggle("自动同步已保存音频", isOn: Binding(get: { recorder.backgroundSync }, set: recorder.setSync))
          Text("待手机确认：\(recorder.pending) 段").font(.footnote)
          Button("同步已保存录音") { recorder.link?.sync(manual: true) }.disabled(!recorder.enabled)
          Text("离线先保存；对讲在手机中确认发送。原音频不会自动删除。").font(.footnote).foregroundStyle(.secondary)
        }.padding(.horizontal, 4)
      }
    }
  }
}

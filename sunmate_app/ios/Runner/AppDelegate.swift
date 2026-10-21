import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var recorderLocalAudio: RecorderLocalAudioChannel?
  private var recorderBackground: RecorderBackgroundChannel?
  private var backgroundTransfer: RecorderBackgroundTransfer?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "SunMateRecorderLocalAudio") {
      recorderLocalAudio = RecorderLocalAudioChannel(messenger: registrar.messenger())
      do {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let transfer = try RecorderBackgroundTransfer(root: root)
        backgroundTransfer = transfer
        recorderBackground = RecorderBackgroundChannel(messenger: registrar.messenger(), receiver: try RecorderBackgroundReceiver(transfer: transfer))
      } catch { /* Leave the existing recording/authentication paths usable. */ }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  override func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    if identifier == RecorderBackgroundTransfer.identifier, let transfer = backgroundTransfer {
      transfer.completion = completionHandler
    } else { super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler) }
  }
}

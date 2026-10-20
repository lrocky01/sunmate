import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var recorderLocalAudio: RecorderLocalAudioChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "SunMateRecorderLocalAudio") {
      recorderLocalAudio = RecorderLocalAudioChannel(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

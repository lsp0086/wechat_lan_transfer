import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var netService: NetService?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerMdnsChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// N1：mDNS 发布通道（iOS Bonjour `_wlt._tcp`，端口为 TCP 文件端口）。
  private func registerMdnsChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "wechat_lan_transfer/mdns",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "register":
        guard let args = call.arguments as? [String: Any],
              let name = args["name"] as? String,
              let port = args["port"] as? Int, port > 0 else {
          result(FlutterError(code: "bad_args", message: "name/port required", details: nil))
          return
        }
        let deviceId = args["deviceId"] as? String ?? ""
        let udpPort = args["udpPort"] as? Int ?? 0
        self?.registerBonjour(name: name, port: port, deviceId: deviceId, udpPort: udpPort)
        result(name)
      case "unregister":
        self?.unregisterBonjour()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerBonjour(name: String, port: Int, deviceId: String, udpPort: Int) {
    unregisterBonjour()
    // NetService 的 port 参数为 Int32（Obj-C int32_t），Swift 6 不再隐式转换
    let service = NetService(domain: "", type: "_wlt._tcp.", name: name, port: Int32(port))
    service.includesPeerToPeer = true
    // N1：TXT 携带身份与 UDP 端口（须在 publish 前设置）
    var txt: [String: Data] = ["name": Data(name.utf8)]
    if !deviceId.isEmpty {
      txt["deviceId"] = Data(deviceId.utf8)
      txt["udpPort"] = Data(String(udpPort).utf8)
    }
    service.setTXTRecord(NetService.data(fromTXTRecord: txt))
    service.publish()
    netService = service
  }

  private func unregisterBonjour() {
    guard let service = netService else { return }
    service.stop()
    netService = nil
  }
}

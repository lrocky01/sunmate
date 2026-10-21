import Foundation
import Security
#if canImport(UIKit)
import UIKit
import Flutter
#endif

/// Native file-backed URLSession transfers. Only a single-use upload ticket is
/// attached to an upload; the long-lived archive credential stays in Keychain.
final class RecorderBackgroundTransfer: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
  static let identifier = "com.sunmate.recorder.audio.v1"
  let root: URL
  private(set) var plan: [String: Any] = [:]
  private var states: [String: [String: Any]] = [:]
  private var responseBodies: [Int: Data] = [:]
  private var ticketingFiles = Set<String>()
  var completion: (() -> Void)?
  var changed: (() -> Void)?
  private lazy var session: URLSession = {
    #if os(iOS)
    let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    #else
    let config = URLSessionConfiguration.ephemeral
    #endif
    config.allowsCellularAccess = true
    config.timeoutIntervalForResource = 86400
    return URLSession(configuration: config, delegate: self, delegateQueue: .main)
  }()
  init(root: URL, initialPlan: [String: Any]? = nil) throws {
    self.root = root
    super.init()
    let directory = try RecorderBackgroundFiles.safeDirectory(root, ["recorder_background_v1"])
    let path = directory.appendingPathComponent("transfers.json")
    if FileManager.default.fileExists(atPath: path.path) {
      states = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: [String: Any]] ?? [:]
    }
    plan = initialPlan ?? ((try? Self.readCredential()) ?? [:])
    _ = session
  }
  func persist() throws {
    let path = try RecorderBackgroundFiles.safeDirectory(root, ["recorder_background_v1"]).appendingPathComponent("transfers.json")
    try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]).write(to: path, options: .atomic)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
    #endif
    changed?()
  }
  static func readCredential() throws -> [String: Any] {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: identifier, kSecAttrAccount: "archive", kSecReturnData: true] as CFDictionary, &result)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess, let data = result as? Data, let v = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RecorderBackgroundError.unauthorized }
    return v
  }
  func pause() throws {
    if plan["url"] is String, let flags = plan["policy"] as? [String: Bool] {
      var value = plan; value["policy"] = flags.mapValues { _ in false }; try configure(value)
    }
    session.getAllTasks { tasks in
      DispatchQueue.main.async { for task in tasks { task.cancel() }
      }
    }
  }
  func configure(_ value: [String: Any]) throws {
    guard let url = value["url"] as? String, let parsed = URLComponents(string: url),
          ["https", "http"].contains(parsed.scheme ?? ""), parsed.host != nil,
          parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
          let policy = value["policy"] as? [String: Bool], let token = value["token"] as? String,
          !token.isEmpty, token.rangeOfCharacter(from: .newlines) == nil else { throw RecorderBackgroundError.invalid }
    _ = policy
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.identifier, kSecAttrAccount: "archive"]
    let attrs: [CFString: Any] = [kSecValueData: try JSONSerialization.data(withJSONObject: value), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      guard SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw RecorderBackgroundError.unauthorized }
    } else if status != errSecSuccess { throw RecorderBackgroundError.unauthorized }
    plan = value
    session.getAllTasks { tasks in
      DispatchQueue.main.async {
      for task in tasks {
        guard let id = task.taskDescription, let row = self.states[id], let meta = row["metadata"] as? [String: Any],
              let purpose = meta["purpose"] as? String else { task.cancel(); continue }
        if policy[purpose + "Upload"] != true || task.originalRequest?.allowsCellularAccess != (policy["cellular"] == true) { task.cancel() }
      }

      }
    }
  }
  func api(_ action: String, body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard let base = plan["url"] as? String, let url = URL(string: base + "/audio/" + action), let token = plan["token"] as? String,
          let identity = plan["identity"] as? [String: String] else { completion(.failure(RecorderBackgroundError.unauthorized)); return }
    var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for key in ["serverId", "libraryId"] { request.setValue(identity[key], forHTTPHeaderField: "X-Sunmate-" + key) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body.merging(["schema": "sunmate.audio.v1"]) { _, n in n })
    let client = URLSession(configuration: .ephemeral, delegate: RejectRecorderRedirects(), delegateQueue: nil)
    client.dataTask(with: request) { data, response, error in
      defer { client.finishTasksAndInvalidate() }
      let result: Result<[String: Any], Error>
      if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data = data, data.count <= 2097152,
         let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["schema"] as? String == "sunmate.audio.v1" { result = .success(value) }
      else { result = .failure(RecorderBackgroundError.unauthorized) }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }
  func enqueue(_ file: URL, metadata: [String: Any]) {
    let purpose = metadata["purpose"] as? String ?? ""
    guard (plan["policy"] as? [String: Bool])?[purpose + "Upload"] == true else { return }
    if ticketingFiles.contains(file.path) || states.values.contains(where: { ["received", "uploading", "queued"].contains($0["state"] as? String ?? "") && $0["file"] as? String == file.path && $0["target"] as? String == plan["target"] as? String }) { return }
    let pending = states.first { $0.key.hasPrefix("local-") && $0.value["file"] as? String == file.path && $0.value["target"] as? String == plan["target"] as? String }?.key ?? "local-" + UUID().uuidString
    states[pending] = ["state": "needs_ticket", "file": file.path, "metadata": metadata, "target": plan["target"] ?? ""]
    do { try persist() } catch { return }
    ticketingFiles.insert(file.path)
    let target = plan["target"] as? String
    api("tickets", body: metadata) { result in
      defer { self.ticketingFiles.remove(file.path) }
      guard target == self.plan["target"] as? String, (self.plan["policy"] as? [String: Bool])?[purpose + "Upload"] == true else { return }
      do {
        let value = try result.get()
        guard let id = value["id"] as? String, id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw RecorderBackgroundError.invalid }
        if value["received"] as? Bool == true {
          self.states.removeValue(forKey: pending) // Only the pending task index, never the audio file.
          self.states[id] = ["state": "received", "metadata": metadata, "file": file.path, "target": self.plan["target"] ?? ""]; try self.persist(); return
        }
        guard let ticket = value["uploadToken"] as? String, let base = self.plan["url"] as? String,
              let url = URL(string: base + "/audio/upload/" + id) else { throw RecorderBackgroundError.invalid }
        if self.states[id]?["state"] as? String == "uploading" { self.states.removeValue(forKey: pending); try self.persist(); return }
        self.states.removeValue(forKey: pending)
        self.states[id] = ["state": "queued", "metadata": metadata, "file": file.path, "target": self.plan["target"] ?? ""]
        try self.persist() // Persist before creating a daemon-owned task.
        var request = URLRequest(url: url); request.httpMethod = "PUT"
        request.setValue("Bearer " + ticket, forHTTPHeaderField: "Authorization")
        request.setValue("audio/ogg", forHTTPHeaderField: "Content-Type")
        request.setValue(String((metadata["bytes"] as? NSNumber)?.intValue ?? 0), forHTTPHeaderField: "Content-Length")
        let cellular = (self.plan["policy"] as? [String: Bool])?["cellular"] == true
        request.allowsCellularAccess = cellular
        let task = self.session.uploadTask(with: request, fromFile: file)
        task.taskDescription = id
        self.states[id]?["state"] = "uploading"; try self.persist(); task.resume()
      } catch { try? self.persist() }
    }
  }
  func snapshot() -> [[String: Any]] { states.map { $0.value.merging(["id": $0.key]) { _, n in n } } }
  func recover() {
    session.getAllTasks { tasks in
      DispatchQueue.main.async {
      let live = Set(tasks.compactMap { $0.taskDescription })
      var attempted = 0
      for (id, row) in Array(self.states) where row["state"] as? String != "received" && !live.contains(id) {
        if attempted >= 20 { break }
        guard row["target"] as? String == self.plan["target"] as? String else { continue }
        if let path = row["file"] as? String, let meta = row["metadata"] as? [String: Any] {
          attempted += 1
          self.states[id]?["state"] = "checking_receipt"
          // Ticket endpoint checks receipt before allowing the same SHA to upload.
          self.enqueue(URL(fileURLWithPath: path), metadata: meta)
        }
      }

      }
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    var body = responseBodies[dataTask.taskIdentifier] ?? Data()
    if body.count + data.count > 65536 { dataTask.cancel(); return }
    body.append(data); responseBodies[dataTask.taskIdentifier] = body
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    defer { responseBodies.removeValue(forKey: task.taskIdentifier) }
    guard let id = task.taskDescription, let meta = states[id]?["metadata"] as? [String: Any] else { return }
    let data = responseBodies[task.taskIdentifier] ?? Data()
    let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let accepted = error == nil && (task.response as? HTTPURLResponse)?.statusCode == 200 && value?["received"] as? Bool == true && value?["id"] as? String == id && value?["sha"] as? String == meta["sha"] as? String
    states[id]?["state"] = accepted ? "received" : "receipt_unknown"
    try? persist() // A transport completion alone never means the server committed.
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let done = completion; completion = nil; DispatchQueue.main.async { done?() }
  }
}

private final class RejectRecorderRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

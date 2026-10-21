import Foundation

// Synthetic local HTTP harness; initialPlan avoids reading the real Keychain.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
let transfer = try RecorderBackgroundTransfer(root: root, initialPlan: fixture["plan"] as? [String: Any])
transfer.enqueue(root.appendingPathComponent("synthetic.ogg"), metadata: fixture["metadata"] as! [String: Any])
let until = Date().addingTimeInterval(15)
while Date() < until && !transfer.snapshot().contains(where: { $0["state"] as? String == "received" }) {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
let accepted = transfer.snapshot().filter { $0["state"] as? String == "received" }.count
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["accepted": accepted]))
exit(accepted == 1 ? 0 : 2)

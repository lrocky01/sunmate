// Synthetic transport only. Never linked into Runner or used as iOS evidence.
import Foundation
public enum CBPeripheralState { case connected, disconnected }
public enum CBCharacteristicWriteType { case withoutResponse }
public final class CBUUID: NSObject {
  public let uuidString: String
  public init(_ string: String) { uuidString = string }
}
public final class CBCharacteristic: NSObject {
  public let uuid: CBUUID
  public var value: Data?
  public weak var service: CBService?
  public init(_ string: String) { uuid = CBUUID(string) }
}
public final class CBService: NSObject {
  public let uuid = CBUUID("00010203-0405-0607-0809-0a0b0c0d1930")
  public var characteristics: [CBCharacteristic]?
  public init(_ chrs: [CBCharacteristic]) { super.init(); characteristics = chrs; for chr in chrs { chr.service = self } }
}
public final class CBPeripheral: NSObject {
  public var state: CBPeripheralState = .connected
  public var services: [CBService]?
  public var canSendWriteWithoutResponse = true
  public var writer: ((Data) -> Void)?
  public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 512 }
  public func writeValue(_ data: Data, for chr: CBCharacteristic, type: CBCharacteristicWriteType) { writer?(data) }
}

import Foundation
#if canImport(HealthKit)
import HealthKit

/// Health samples never enter audio metadata, WatchConnectivity or network code.
final class WatchHealthReadOnly {
  private let health = HKHealthStore()
  private let defaults: UserDefaults
  private(set) var enabled: Bool
  private(set) var selected: Set<String>
  private var generation = 0
  static let allowed = Set(["heart", "hrv", "steps", "sleep"])
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.bool(forKey: "sunmate.watch.health.read.v1")
    selected = Set(defaults.stringArray(forKey: "sunmate.watch.health.types.v1") ?? []).intersection(Self.allowed)
  }
  private func quantities(_ key: String) -> [HKQuantityTypeIdentifier] {
    switch key {
    case "heart": return [.heartRate, .restingHeartRate]
    case "hrv": return [.heartRateVariabilitySDNN]
    case "steps": return [.stepCount]
    default: return []
    }
  }
  func configure(enabled: Bool, types: Set<String>, completion: @escaping (Bool) -> Void) {
    guard types.isSubset(of: Self.allowed), !enabled || !types.isEmpty else { completion(false); return }
    generation += 1
    let generation = self.generation
    if !enabled {
      self.enabled = false; defaults.set(false, forKey: "sunmate.watch.health.read.v1"); completion(true); return
    }
    guard HKHealthStore.isHealthDataAvailable() else { completion(false); return }
    var read = Set<HKObjectType>()
    for key in types { for name in quantities(key) { if let t = HKObjectType.quantityType(forIdentifier: name) { read.insert(t) } } }
    if types.contains("sleep"), let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { read.insert(t) }
    // An authorization request succeeding does not reveal the user's read decision.
    health.requestAuthorization(toShare: Set<HKSampleType>(), read: read) { completed, _ in
      DispatchQueue.main.async {
        guard generation == self.generation else { completion(false); return }
        if completed {
          self.enabled = true; self.selected = types
          self.defaults.set(true, forKey: "sunmate.watch.health.read.v1")
          self.defaults.set(types.sorted(), forKey: "sunmate.watch.health.types.v1")
        }
        completion(completed)
      }
    }
  }
  func snapshot(_ completion: @escaping ([String: Any]) -> Void) {
    let generation = self.generation
    let base: [String: Any] = ["enabled": enabled, "types": selected.sorted(), "available": HKHealthStore.isHealthDataAvailable(), "externalSharing": false]
    guard enabled, HKHealthStore.isHealthDataAvailable() else { completion(base.merging(["samples": []]) { _, n in n }); return }
    let group = DispatchGroup(), lock = NSLock(), now = Date()
    var samples: [[String: Any]] = []
    func add(_ value: [String: Any]) { lock.lock(); samples.append(value); lock.unlock() }
    for key in selected where key != "sleep" {
      for name in quantities(key) {
        guard let type = HKObjectType.quantityType(forIdentifier: name) else { continue }
        group.enter()
        let since = name == .stepCount ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-7 * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: since, end: now, options: .strictStartDate)
        if name == .stepCount {
          health.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
            defer { group.leave() }
            if error == nil, let quantity = result?.sumQuantity() {
              add(["kind": "steps", "value": quantity.doubleValue(for: .count()), "unit": "步", "from": ISO8601DateFormatter().string(from: since), "to": ISO8601DateFormatter().string(from: now), "source": "HealthKit统计"])
            }
          })
        } else {
          health.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, values, error in
            defer { group.leave() }
            guard error == nil, let value = values?.first as? HKQuantitySample else { return }
            let hrv = name == .heartRateVariabilitySDNN
            let unit = hrv ? HKUnit.secondUnit(with: .milli) : HKUnit.count().unitDivided(by: .minute())
            add(["kind": hrv ? "hrvSDNN" : name == .restingHeartRate ? "restingHeartRate" : "heartRate", "value": value.quantity.doubleValue(for: unit), "unit": hrv ? "ms" : "次/分钟", "from": ISO8601DateFormatter().string(from: value.startDate), "to": ISO8601DateFormatter().string(from: value.endDate), "source": value.sourceRevision.source.name])
          })
        }
      }
    }
    if selected.contains("sleep"), let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      group.enter()
      let since = now.addingTimeInterval(-24 * 3600)
      health.execute(HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: now), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, values, error in
        defer { group.leave() }
        guard error == nil else { return }
        // Union actual asleep intervals to avoid counting overlapping devices twice.
        let intervals = (values as? [HKCategorySample] ?? []).filter { [1, 3, 4, 5].contains($0.value) }
          .map { (max($0.startDate, since), min($0.endDate, now)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var start: Date?, end: Date?, seconds: TimeInterval = 0
        for interval in intervals {
          if let e = end, interval.0 > e { seconds += e.timeIntervalSince(start!); start = interval.0; end = interval.1 }
          else { start = start ?? interval.0; end = max(end ?? interval.1, interval.1) }
        }
        if let s = start, let e = end { seconds += e.timeIntervalSince(s) }
        if !intervals.isEmpty { add(["kind": "sleep", "value": seconds / 3600, "unit": "小时", "from": ISO8601DateFormatter().string(from: since), "to": ISO8601DateFormatter().string(from: now), "source": "HealthKit睡眠区间并集"]) }
      })
    }
    group.notify(queue: .main) {
      guard self.enabled, generation == self.generation else { completion(["enabled": self.enabled, "types": self.selected.sorted(), "samples": [], "externalSharing": false]); return }
      completion(base.merging(["samples": samples, "message": "仅显示实际可读样本；无数据不代表未授权。受保护数据可能需解锁后重试。 "]) { _, n in n })
    }
  }
}
#endif

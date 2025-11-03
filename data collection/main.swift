import IOKit
import IOKit.graphics
import Quartz
import Foundation
import Darwin
import HealthKit
import FirebaseCore
import FirebaseFirestore

// ---------------- Firebase helpers ----------------

func setupFirebase() {
    let plistRelativePath = "./Heist_Hackathon/GoogleService-Info.plist"
    if FileManager.default.fileExists(atPath: plistRelativePath) {
        if let options = FirebaseOptions(contentsOfFile: plistRelativePath) {
            FirebaseApp.configure(options: options)
            print("Firebase configured from plist at \(plistRelativePath)")
            return
        } else {
            print("Found plist at \(plistRelativePath) but failed to create FirebaseOptions.")
        }
    } else {
        print("No GoogleService-Info.plist found at \(plistRelativePath). Firebase disabled.")
    }
}

func sendToFirebase(output: Output) {
    guard FirebaseApp.app() != nil else {
        print("→ Firebase not configured; skipping upload. Output JSON:")
        do {
            let json = try JSONEncoder().encode(output)
            print(String(data: json, encoding: .utf8) ?? "<encoding error>")
        } catch {
            print("Error encoding output for print: \(error)")
        }
        return
    }

    let db = Firestore.firestore()
    do {
        let jsonData = try JSONEncoder().encode(output)
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("Error converting encoded output to dictionary")
            return
        }

        db.collection("senseShiftData").addDocument(data: dict) { error in
            if let error = error {
                print("Firestore upload failed: \(error)")
            } else {
                print("Data uploaded to Firestore at \(Date())")
            }
        }
    } catch {
        print("Error preparing data for Firebase: \(error)")
    }
}

// ---------------------- MacOS System -----------------------

class KeyTapTracker {
    private(set) var tapCount = 0
    private var windowStart = Date()

    func registerTap() {
        tapCount += 1
    }

    // Always returns the taps in the sliding window; if window hasn't elapsed, return current count (you can change behavior if you prefer nil)
    func checkAndResetIfElapsed(interval: TimeInterval = 10) -> Int? {
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)

        if elapsed >= interval {
            let taps = tapCount
            tapCount = 0
            windowStart = now
            return taps
        }
        return nil
    }
}

/// Callback function for keyboard events
func processKeyboardTap(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let tracker = Unmanaged<KeyTapTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.registerTap()

    return Unmanaged.passUnretained(event)
}

class MacOSSystem {
    // Keep a strong reference to the event tap so it isn't deallocated
    private var eventTap: CFMachPort?
    let keyTapTracker = KeyTapTracker()

    func getBrightness() -> Float? {
        var iterator = io_iterator_t()

        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IODisplayConnect"),
                                           &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness) == kIOReturnSuccess {
                return brightness
            }
        }

        return nil
    }

    func getKeyboardTaps() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(keyTapTracker).toOpaque())

        guard let event_task = CGEventTapCreate(
            kCGHIDEventTap,
            .headInsertEventTap,
            .listenOnly,
            mask,
            processKeyboardTap,
            refcon
        ) else {
            return false
        }

        eventTap = event_task
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, event_task, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEventTapEnable(event_task, true)

        return true
    }

    func getSystemUptime() -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride

        let result = sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0)
        if result != 0 {
            perror("sysctl")
            return nil
        }

        let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        return Date().timeIntervalSince(bootDate)
    }
}

// ----------------------- HealthKit wrapper -----------------------

class HealthDataManager {
    let healthStore = HKHealthStore()

    func requestAuthorization() async throws {
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]

        try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authorization failed"]))
                }
            }
        }
    }

    func fetchQuantitySamples(
        for identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> [Double] {

        return try await withCheckedThrowingContinuation { continuation in
            guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
                continuation.resume(returning: [])
                return
            }

            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

            let query = HKSampleQuery(sampleType: quantityType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let values: [Double] = (results as? [HKQuantitySample])?.map {
                    $0.quantity.doubleValue(for: unit)
                } ?? []

                continuation.resume(returning: values)
            }

            healthStore.execute(query)
        }
    }

    func fetchSleepAnalysis(startDate: Date, endDate: Date) async throws -> Double {
        return try await withCheckedThrowingContinuation { continuation in
            guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
                continuation.resume(returning: 0)
                return
            }

            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])

            let query = HKSampleQuery(sampleType: sleepType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let samples = results as? [HKCategorySample] else {
                    continuation.resume(returning: 0)
                    return
                }

                let asleepSamples = samples.filter {
                    let val = HKCategoryValueSleepAnalysis(rawValue: $0.value)
                    return val == .asleepUnspecified || val == .asleepCore || val == .asleepDeep || val == .asleepREM
                }

                let totalSleepSeconds = asleepSamples.reduce(0.0) { partialResult, sample in
                    partialResult + sample.endDate.timeIntervalSince(sample.startDate)
                }

                continuation.resume(returning: totalSleepSeconds / 3600.0)
            }

            healthStore.execute(query)
        }
    }

    func fetchSumQuantitySamples(
        for identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        startDate: Date,
        endDate: Date
    ) async throws -> Double {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return 0
        }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

            let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let sum = statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: sum)
            }

            healthStore.execute(query)
        }
    }
}

// ----------------------- Main Application -----------------------

struct Output: Codable {
    let currentTime: Date
    let brightness: Float?
    let keyboardTaps: Int?
    let systemUptime: TimeInterval?
    let stepCount: Double?
    let sleepHours: Double?
    let heartRates: [Double]?
    let bloodOxygenPercent: [Double]?
    let respiratoryRates: [Double]?
    let caloriesBurned: [Double]?
}

@main
class MyApp {
    static func main() {
        // Setup Firebase if plist is present (safe no-op otherwise)
        setupFirebase()

        let system = MacOSSystem()
        let healthManager = HealthDataManager()

        // Create keyboard event tap
        guard system.getKeyboardTaps() else {
            print("Failed to create keyboard event tap.")
            return
        }

        // Determine if we can use HealthKit (non-fatal)
        var healthAvailable = HKHealthStore.isHealthDataAvailable()
        if healthAvailable {
            Task {
                do {
                    try await healthManager.requestAuthorization()
                    print("HealthKit authorized")
                } catch {
                    print("HealthKit auth failed: \(error)")
                    healthAvailable = false
                }
            }
        } else {
            print("HealthKit not available on this device — skipping biometric data.")
        }

        // Prevent overlapping runs
        var isRunning = false

        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            // avoid overlapping executions
            guard !isRunning else { return }
            isRunning = true

            Task {
                defer { isRunning = false }

                let keyboardTap = system.keyTapTracker.checkAndResetIfElapsed(interval: 10) ?? 0
                let brightness = system.getBrightness()
                let systemUptime = system.getSystemUptime()

                // Prepare optional health variables
                var heartRatesValues: [Double]? = nil
                var spo2Values: [Double]? = nil
                var respRatesValues: [Double]? = nil
                var caloriesValues: [Double]? = nil
                var totalSteps: Double? = nil
                var totalSleep: Double? = nil

                if healthAvailable {
                    do {
                        async let heartRates = healthManager.fetchQuantitySamples(for: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: Date().addingTimeInterval(-3600), endDate: Date())
                        async let spo2 = healthManager.fetchQuantitySamples(for: .oxygenSaturation, unit: HKUnit.percent(), startDate: Date().addingTimeInterval(-3600), endDate: Date())
                        async let respRates = healthManager.fetchQuantitySamples(for: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: Date().addingTimeInterval(-3600), endDate: Date())
                        async let calories = healthManager.fetchQuantitySamples(for: .activeEnergyBurned, unit: .kilocalorie(), startDate: Date().addingTimeInterval(-3600), endDate: Date())
                        async let stepCount = healthManager.fetchSumQuantitySamples(for: .stepCount, unit: .count(), startDate: Date().addingTimeInterval(-3600), endDate: Date())
                        let sleepStartDate = Calendar.current.startOfDay(for: Date())
                        let sleepEndDate = Calendar.current.date(byAdding: .day, value: 1, to: sleepStartDate)!
                        async let sleepHours = healthManager.fetchSleepAnalysis(startDate: sleepStartDate, endDate: sleepEndDate)

                        (heartRatesValues, spo2Values, respRatesValues, caloriesValues, totalSteps, totalSleep) =
                            try await (heartRates, spo2, respRates, calories, stepCount, sleepHours)
                    } catch {
                        print("HealthKit fetch failed: \(error)")
                        // if HealthKit fails for any reason, we'll send system-only data (biometric vars remain nil)
                    }
                }

                let output = Output(
                    currentTime: Date(),
                    brightness: brightness,
                    keyboardTaps: keyboardTap,
                    systemUptime: systemUptime,
                    stepCount: totalSteps,
                    sleepHours: totalSleep,
                    heartRates: heartRatesValues,
                    bloodOxygenPercent: spo2Values?.map { $0 * 100 },
                    respiratoryRates: respRatesValues,
                    caloriesBurned: caloriesValues
                )

                sendToFirebase(output: output)
            }
        }

        print("Starting run loop…")
        CFRunLoopRun()
    }
}

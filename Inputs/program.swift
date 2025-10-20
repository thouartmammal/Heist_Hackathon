import IOKit
import IOKit.graphics
import Quartz
import Foundation
import Darwin
import HealthKit 

// ---------------------- MacOS System -----------------------

class KeyTapTracker {
    var tapCount = 0
    var windowStart = Date()

    func registerTap() {
        tapCount += 1
    }

    func checkAndReset() -> Int? {
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)

        if elapsed >= 10 {
            let taps = tapCount
            tapCount = 0
            windowStart = now
            return taps
        }
        return nil 

        // return 0 = no keys were tapped
        // return nil = time interval hasn't finished
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
        
    // Retrieve tracker from refcon
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let tracker = Unmanaged<KeyTapTracker>.fromOpaque(refcon).takeUnretainedValue()

    // increase count
    tracker.registerTap()
        
    if let taps = tracker.checkAndReset() {
        print("Keys tapped in last 10 seconds: \(taps)")
    }
        
    return Unmanaged.passUnretained(event)
}



class MacOSSystem{
    func getBrightness() -> Float? {
        
        var iterator = io_iterator_t()

        // inding IOService objects currently registered by IOKit 

        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IODisplayConnect"),
                                        &iterator) == kIOReturnSuccess 
            else {
                return nil 
            }

        defer { IOObjectRelease(iterator) } // Auto-release when done (end of scrope not currently)
    
        // Iterate through all found services until brightness is found
        // Swift doesn't allow assignment directly in while so you need to write it in this syntax.
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            // kIODisplayBrightnessKey = the parameter we want to get
            if IODisplayGetFloatParameter(service, 0,
                                        kIODisplayBrightnessKey as CFString,
                                        &brightness) == kIOReturnSuccess {
                return brightness
            }
        }

        return nil
    }

    let keyTapTracker = KeyTapTracker()

    func getKeyboardTaps() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(keyTapTracker).toOpaque())

        guard let event_task = CGEventTapCreate(
            kCGHIDEventTap, // lowest-level (hardware) event tap
            .headInsertEventTap, // tap gets events first
            .listenOnly,
            mask, // keyboard event
            processKeyboardTap, // callback function
            refcon // userInfo
        ) else {
            return false
        }

        // Create a run loop source for the tap and add it to the run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, event_task, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEventTapEnable(event_task, true)

        return true
    }

    func getSystemUptime() -> TimeInterval? {
        // mib = Management Information Base
        // mib is an array telling sysctl what info I want.
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]

        // time the system last booted
        var bootTime = timeval()

        // get size of timeval struct to pass to sysctl
        var size = MemoryLayout<timeval>.stride

        // write the value of when the system started to bootTime
        let result = sysctl(
            &mib, // Pointer to the name array
            u_int(mib.count), // number of elements in 'mib'
            &bootTime, // Pointer to output buffer
            &size, // Pointer to size of output buffer
            nil, // input buffer (not used here)
            0) // size of input buffer (not used here)

        if result != 0 {
            perror("sysctl")
            return nil
        }

        // Convert timeval (boot time) to Date
        let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        
        // subtract boot date from current date to get uptime
        let uptime = Date().timeIntervalSince(bootDate)

        return uptime
    }
}

// ----------------------- Biometric Watch Integration -----------------------


class HealthKit {
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

            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
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

                let totalSleepHours = totalSleepSeconds / 3600
                continuation.resume(returning: totalSleepHours)
            }

            healthStore.execute(query)
        }
    }

    // Helpers to get aggregated sums for some data (e.g., steps)
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

    // Fetch all data
    func getAllData() async {
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: -1, to: now)!
        let sleepStartDate = Calendar.current.startOfDay(for: now) // Start of today
        let sleepEndDate = Calendar.current.date(byAdding: .day, value: 1, to: sleepStartDate)!

        do {
            async let heartRates = fetchQuantitySamples(for: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: startDate, endDate: now)
            async let spo2 = fetchQuantitySamples(for: .oxygenSaturation, unit: HKUnit.percent(), startDate: startDate, endDate: now)
            async let respRate = fetchQuantitySamples(for: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: startDate, endDate: now)
            async let calories = fetchQuantitySamples(for: .activeEnergyBurned, unit: .kilocalorie(), startDate: startDate, endDate: now)
            async let stepCount = fetchSumQuantitySamples(for: .stepCount, unit: .count(), startDate: startDate, endDate: now)
            async let sleepHours = fetchSleepAnalysis(startDate: sleepStartDate, endDate: sleepEndDate)

            let (heartRatesValues, spo2Values, respRateValues, caloriesValues, totalSteps, totalSleep) = try await (heartRates, spo2, respRate, calories, stepCount, sleepHours)

        } catch {
            print("Error fetching HealthKit data: \(error)")
        }
    }
}


// ----------------------- Main Application -----------------------

struct Output: Codable {
    let currentTime = Date
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
    static func main(){
        var System = MacOSSystem()  
        var HealthKit = HealthKit()

        // Start the keyboard tap
        guard System.getKeyboardTaps() else {
            print("Failed to create keyboard event tap.")
            return
        }

        // Schedule a timer to run every 10 seconds
    _ = Foundation.Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
        Task {
            let keyboardTap = System.keyTapTracker.checkAndReset()
            let brightness = System.getBrightness()
            let systemUptime = System.getSystemUptime()

            do {
                async let heartRates = HealthKit.fetchQuantitySamples(for: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!, endDate: Date())
                async let spo2 = HealthKit.fetchQuantitySamples(for: .oxygenSaturation, unit: HKUnit.percent(), startDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!, endDate: Date())
                async let respRates = HealthKit.fetchQuantitySamples(for: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), startDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!, endDate: Date())
                async let calories = HealthKit.fetchQuantitySamples(for: .activeEnergyBurned, unit: .kilocalorie(), startDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!, endDate: Date())
                async let stepCount = HealthKit.fetchSumQuantitySamples(for: .stepCount, unit: .count(), startDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!, endDate: Date())
                
                let sleepStartDate = Calendar.current.startOfDay(for: Date())
                let sleepEndDate = Calendar.current.date(byAdding: .day, value: 1, to: sleepStartDate)!
                async let sleepHours = HealthKit.fetchSleepAnalysis(startDate: sleepStartDate, endDate: sleepEndDate)

                let (heartRatesValues, spo2Values, respRatesValues, caloriesValues, totalSteps, totalSleep) = try await (heartRates, spo2, respRates, calories, stepCount, sleepHours)

                let output = Output(
                    currentTime: Date(),
                    brightness: brightness,
                    keyboardTaps: keyboardTap,
                    systemUptime: systemUptime,
                    stepCount: totalSteps,
                    sleepHours: totalSleep,
                    heartRates: heartRatesValues,
                    bloodOxygenPercent: spo2Values.map { $0 * 100 },
                    respiratoryRates: respRatesValues,
                    caloriesBurned: caloriesValues
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(output)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }

            } catch {
                print("Error fetching HealthKit data: \(error)")
            }
        }
    }
        print("Starting run loop...")

        CFRunLoopRun()
    }
}

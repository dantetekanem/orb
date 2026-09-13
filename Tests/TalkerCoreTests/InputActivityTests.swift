import CoreAudio
import XCTest
@testable import TalkerCore

@MainActor
final class InputActivityTests: XCTestCase {
    func testActiveAndInactiveInputPublishChanges() {
        let hal = FakeHAL(processes: [1], inputs: [1: 1])
        let monitor = InputActivityMonitor(backend: hal)
        XCTAssertEqual(monitor.activity, .active)
        var changes: [InputActivity] = []
        monitor.onChange = { changes.append($0) }
        hal.inputs[1] = 0
        hal.emitInput(1)
        XCTAssertEqual(monitor.activity, .inactive)
        XCTAssertEqual(changes, [.inactive])
    }

    func testDuplicateMembershipNotificationsRefreshWithoutRebuildingListeners() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0])
        let monitor = InputActivityMonitor(backend: hal)
        let registrations = hal.registrationCalls, removals = hal.removeCalls
        for _ in 0..<100 { hal.emitProcessList() }
        hal.inputs[1] = 1
        hal.emitProcessList()
        XCTAssertEqual(monitor.activity, .active)
        XCTAssertEqual(hal.registrationCalls, registrations)
        XCTAssertEqual(hal.removeCalls, removals)
        monitor.stop()
    }

    func testRetiredCallbacksCannotRebuildLiveListenersOrPublishOldEvidence() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0, 2: 1])
        let monitor = InputActivityMonitor(backend: hal)
        hal.listed = [1, 2]
        hal.emitProcessList()
        XCTAssertEqual(monitor.activity, .active)
        let reads = hal.readCalls, registrations = hal.registrationCalls, removals = hal.removeCalls
        var changes: [InputActivity] = []
        monitor.onChange = { changes.append($0) }
        hal.inputs[2] = 0
        hal.emitRetiredCallbacks()
        XCTAssertEqual(hal.readCalls, reads)
        XCTAssertEqual(hal.registrationCalls, registrations)
        XCTAssertEqual(hal.removeCalls, removals)
        XCTAssertEqual(monitor.activity, .active)
        XCTAssertTrue(changes.isEmpty)
        hal.emitInput(2)
        XCTAssertEqual(changes, [.inactive])
        monitor.stop()
    }

    func testIncompleteEnumerationAndMissingOrBadInputReadAreUnknown() {
        XCTAssertEqual(InputActivityMonitor(backend: FakeHAL(processes: nil)).activity, .unknown)
        for inputs in [[AudioObjectID: FakeHAL.Read](), [1: .bad]] {
            XCTAssertEqual(InputActivityMonitor(backend: FakeHAL(processes: [1], reads: inputs)).activity, .unknown)
        }
    }

    func testChurnResnapshotsOnceBeforePublishingInactive() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0, 2: 0])
        hal.snapshots = [[1], [1, 2], [1, 2], [1, 2]]
        XCTAssertEqual(InputActivityMonitor(backend: hal).activity, .inactive)
        XCTAssertEqual(hal.inputRegistrations.count, 3)
        XCTAssertEqual(Set(hal.inputRegistrations), [1, 2])
    }

    func testRegistrationFailureIsUnknownAndCleansUp() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0])
        hal.failInputRegistration = true
        XCTAssertEqual(InputActivityMonitor(backend: hal).activity, .unknown)
        XCTAssertGreaterThan(hal.removeCalls, 0)
    }

    func testFailedGlobalRegistrationStaysUnknownUntilRecovery() {
        let hal = FakeHAL(processes: [])
        hal.failListRegistration = true
        let monitor = InputActivityMonitor(backend: hal)
        XCTAssertEqual(monitor.activity, .unknown)
        XCTAssertEqual(monitor.refresh(), .unknown)
        hal.failListRegistration = false
        XCTAssertEqual(monitor.refresh(), .inactive)
    }

    func testRefreshIncludesInputThatJoinsDuringScan() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0, 2: 1])
        let monitor = InputActivityMonitor(backend: hal)
        hal.snapshots = [[1], [1, 2], [1, 2], [1, 2]]
        XCTAssertEqual(monitor.refresh(), .active)
        hal.snapshots = [[1], [1, 2], [1], [1, 2], [1], [1, 2]]
        XCTAssertEqual(monitor.refresh(), .unknown)
    }

    func testInvalidMembershipAndInputValuesFailQuiet() {
        for processes: [AudioObjectID] in [[0], [1, 1], Array(1...1025)] {
            let inputs = Dictionary(processes.map { ($0, UInt32(0)) }, uniquingKeysWith: { a, _ in a })
            XCTAssertEqual(InputActivityMonitor(backend: FakeHAL(processes: processes, inputs: inputs)).activity, .unknown)
        }
        XCTAssertEqual(InputActivityMonitor(backend: FakeHAL(processes: [1], inputs: [1: 2])).activity, .unknown)
    }

    func testServiceResetPublishesUnknownThenRebuilds() {
        let hal = FakeHAL(processes: [1], inputs: [1: 1])
        let monitor = InputActivityMonitor(backend: hal)
        var changes: [InputActivity] = []
        monitor.onChange = { changes.append($0) }
        hal.inputs[1] = 0
        hal.emitServiceReset()
        XCTAssertEqual(monitor.activity, .inactive)
        XCTAssertEqual(changes, [.unknown, .inactive])
    }

    func testStopCleansListenersAndLateCallbacksCannotReviveMonitor() {
        let hal = FakeHAL(processes: [1], inputs: [1: 0])
        let monitor = InputActivityMonitor(backend: hal)
        var changes: [InputActivity] = []
        monitor.onChange = { changes.append($0) }
        monitor.stop()
        hal.inputs[1] = 1
        hal.emitRetiredCallbacks()
        XCTAssertEqual(monitor.activity, .unknown)
        XCTAssertEqual(monitor.refresh(), .unknown)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertGreaterThan(hal.removeCalls, 0)
    }
}

@MainActor
private final class FakeHAL: InputActivityHALBackend {
    enum Read { case value(UInt32), bad }
    var inputs: [AudioObjectID: UInt32] = [:]
    var reads: [AudioObjectID: Read] = [:]
    var snapshots: [[AudioObjectID]] = []
    var failInputRegistration = false
    var failListRegistration = false
    var listed: [AudioObjectID]?
    private var listCallbacks: [() -> Void] = []
    private var resetCallbacks: [() -> Void] = []
    private var inputCallbacks: [AudioObjectID: [() -> Void]] = [:]
    private var retired: [() -> Void] = []
    var inputRegistrations: [AudioObjectID] = []
    var removeCalls = 0, registrationCalls = 0, readCalls = 0

    init(processes: [AudioObjectID]?, inputs: [AudioObjectID: UInt32] = [:], reads: [AudioObjectID: Read] = [:]) {
        listed = processes; self.inputs = inputs; self.reads = reads
    }

    func processObjects() -> [AudioObjectID]? {
        readCalls += 1
        return snapshots.isEmpty ? listed : snapshots.removeFirst()
    }
    func inputIsRunning(_ process: AudioObjectID) -> UInt32? {
        readCalls += 1
        if case .bad? = reads[process] { return nil }
        if case let .value(value)? = reads[process] { return value }
        return inputs[process]
    }
    func addProcessListListener(_ callback: @escaping () -> Void) -> Bool {
        registrationCalls += 1
        guard !failListRegistration else { return false }
        listCallbacks.append(callback); return true
    }
    func addServiceRestartListener(_ callback: @escaping () -> Void) -> Bool {
        registrationCalls += 1
        resetCallbacks.append(callback); return true
    }
    func addInputListener(_ process: AudioObjectID, _ callback: @escaping () -> Void) -> Bool {
        registrationCalls += 1
        inputRegistrations.append(process)
        guard !failInputRegistration else { return false }
        inputCallbacks[process, default: []].append(callback); return true
    }
    func removeAllListeners() {
        removeCalls += 1
        retired += listCallbacks + resetCallbacks + inputCallbacks.values.flatMap { $0 }
        listCallbacks = []; resetCallbacks = []; inputCallbacks = [:]
    }
    func emitProcessList() { listCallbacks.forEach { $0() } }
    func emitInput(_ process: AudioObjectID) { inputCallbacks[process]?.forEach { $0() } }
    func emitServiceReset() { resetCallbacks.forEach { $0() } }
    func emitRetiredCallbacks() { retired.forEach { $0() } }
}

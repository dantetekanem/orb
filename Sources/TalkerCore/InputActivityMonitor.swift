import CoreAudio
import Dispatch

public enum InputActivity: String {
    case active, inactive, unknown
}

@MainActor
public protocol InputActivityMonitoring: AnyObject {
    var activity: InputActivity { get }
    var onChange: ((InputActivity) -> Void)? { get set }
    func refresh() -> InputActivity
    func stop()
}

@MainActor
protocol InputActivityHALBackend: AnyObject {
    func processObjects() -> [AudioObjectID]?
    func inputIsRunning(_ process: AudioObjectID) -> UInt32?
    func addProcessListListener(_ callback: @escaping () -> Void) -> Bool
    func addServiceRestartListener(_ callback: @escaping () -> Void) -> Bool
    func addInputListener(_ process: AudioObjectID, _ callback: @escaping () -> Void) -> Bool
    func removeAllListeners()
}

@MainActor
public final class InputActivityMonitor: InputActivityMonitoring {
    public private(set) var activity: InputActivity = .unknown
    public var onChange: ((InputActivity) -> Void)?

    private let backend: InputActivityHALBackend
    private var membership: Set<AudioObjectID> = []
    private var stopped = false
    private var ready = false
    private var listenerGeneration: UInt64 = 0

    public convenience init() {
        self.init(backend: CoreAudioInputActivityHAL())
    }

    init(backend: InputActivityHALBackend) {
        self.backend = backend
        establishListeners()
    }

    public func refresh() -> InputActivity {
        guard !stopped else { return .unknown }
        guard ready else { establishListeners(); return activity }
        guard let current = snapshot() else {
            publish(.unknown)
            return activity
        }
        guard current == membership else { establishListeners(); return activity }
        let observed = activity(for: current)
        guard let final = snapshot() else { publish(.unknown); return activity }
        guard final == current else { establishListeners(); return activity }
        publish(observed)
        return activity
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        retireListeners()
        membership = []
        ready = false
        onChange = nil
        activity = .unknown
    }

    private func snapshot() -> Set<AudioObjectID>? {
        guard let processes = backend.processObjects(), processes.count <= 1024,
              !processes.contains(kAudioObjectUnknown), Set(processes).count == processes.count else { return nil }
        return Set(processes)
    }

    private func establishListeners() {
        guard !stopped else { return }
        ready = false
        retireListeners()
        membership = []
        for _ in 0...1 {
            guard backend.addProcessListListener(currentListener { _ = $0.refresh() }),
                  backend.addServiceRestartListener(currentListener { $0.serviceRestarted() }),
                  let initial = snapshot(), registerInputListeners(for: initial) else {
                retireListeners()
                publish(.unknown)
                return
            }
            let observed = activity(for: initial)
            if let final = snapshot(), initial == final {
                membership = final
                ready = true
                publish(observed)
                return
            }
            retireListeners()
        }
        publish(.unknown)
    }

    private func registerInputListeners(for processes: Set<AudioObjectID>) -> Bool {
        for process in processes {
            guard backend.addInputListener(process, currentListener { _ = $0.refresh() }) else { return false }
        }
        return true
    }

    private func retireListeners() {
        listenerGeneration &+= 1
        backend.removeAllListeners()
    }

    private func currentListener(_ action: @escaping (InputActivityMonitor) -> Void) -> () -> Void {
        let generation = listenerGeneration
        return { [weak self] in
            guard let self, !self.stopped, self.listenerGeneration == generation else { return }
            action(self)
        }
    }

    private func serviceRestarted() {
        guard !stopped else { return }
        publish(.unknown)
        establishListeners()
    }

    private func activity(for processes: Set<AudioObjectID>) -> InputActivity {
        for process in processes {
            guard let inputRunning = backend.inputIsRunning(process), inputRunning <= 1 else { return .unknown }
            if inputRunning == 1 { return .active }
        }
        return .inactive
    }

    private func publish(_ value: InputActivity) {
        guard activity != value else { return }
        activity = value
        onChange?(value)
    }
}

@MainActor
private final class CoreAudioInputActivityHAL: InputActivityHALBackend {
    private struct Registration {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let callback: AudioObjectPropertyListenerBlock
    }

    private var registrations: [Registration] = []

    deinit {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, registration.queue, registration.callback)
        }
    }

    func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectHasProperty(system, &address),
              AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size <= 1024 * MemoryLayout<AudioObjectID>.stride,
              size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else { return nil }
        let expectedSize = size
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard !result.isEmpty else { return result }
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size == expectedSize else { return nil }
        return result
    }

    func inputIsRunning(_ process: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectHasProperty(process, &address),
              AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.stride else { return nil }
        return value
    }

    func addProcessListListener(_ callback: @escaping () -> Void) -> Bool {
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, callback)
    }

    func addServiceRestartListener(_ callback: @escaping () -> Void) -> Bool {
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted, callback)
    }

    func addInputListener(_ process: AudioObjectID, _ callback: @escaping () -> Void) -> Bool {
        addListener(process, kAudioProcessPropertyIsRunningInput, callback)
    }

    func removeAllListeners() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, registration.queue, registration.callback)
        }
        registrations = []
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ callback: @escaping () -> Void) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let queue = DispatchQueue.main
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in callback() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return false }
        registrations.append(Registration(object: object, address: address, queue: queue, callback: block))
        return true
    }
}

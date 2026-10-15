import Carbon

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let keyCode: Int
    private let modifiers: Int
    private var retry: Timer?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        self.keyCode = keyCode
        self.modifiers = modifiers
        Self.actions[id] = action
        if !register() {
            // Taken, often by the previous copy of Tendedero still quitting
            // while this one starts. Try again until it is free.
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
                if self?.register() ?? true { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retry = timer
        }
    }

    deinit {
        retry?.invalidate()
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private func register() -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            log.debug("Shortcut \(self.keyCode, privacy: .public) registered")
            return true
        }
        log.error("Shortcut \(self.keyCode, privacy: .public) is taken (\(status, privacy: .public)), retrying")
        return false
    }

    /// One handler for every shortcut; the pressed one is told by its id.
    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

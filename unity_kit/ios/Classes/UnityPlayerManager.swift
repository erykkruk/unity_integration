import Foundation
import UIKit
import UnityFramework

/// Singleton manager for the Unity player lifecycle.
///
/// Unity only supports a single instance per process. This manager owns that
/// instance and survives Flutter navigation so the player is not recreated
/// when views are pushed or popped (Issue #1 fix).
///
/// Resource tracking is explicit: callers must pair `initialize()` with
/// `dispose()` and monitor state via `isInitialized` / `isLoaded` /
/// `isPaused` (Issue #5 fix).
///
/// All mutable state is protected by `stateLock` for thread safety (iOS-C1).
final class UnityPlayerManager: NSObject {

    // MARK: - Singleton

    static let shared = UnityPlayerManager()

    // MARK: - Thread Safety (iOS-C1)

    private let stateLock = NSLock()

    // MARK: - State (backing storage, access only under stateLock)

    private var _unityFramework: UnityFramework?
    private var _isInitialized = false
    private var _isPaused = false
    private var _isLoaded = false

    // MARK: - Thread-Safe Computed Properties

    var isInitialized: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isInitialized
    }

    var isPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPaused
    }

    var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isLoaded
    }

    // MARK: - Listeners

    private let listenerLock = NSLock()
    private var listeners: [WeakListener] = []

    // MARK: - App Lifecycle

    private var isObservingAppLifecycle = false

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Initialization

    /// Load and initialize the UnityFramework.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops.
    /// Returns `true` if Unity is initialized (or was already), `false` on failure (iOS-H4).
    @discardableResult
    func initialize() -> Bool {
        stateLock.lock()
        guard !_isInitialized else {
            stateLock.unlock()
            return true
        }
        stateLock.unlock()

        guard let framework = loadFramework() else {
            NSLog("[UnityKit] Failed to load UnityFramework.framework")
            return false
        }

        framework.setDataBundleId("com.unity3d.framework")
        framework.register(self)
        framework.runEmbedded(
            withArgc: CommandLine.argc,
            argv: CommandLine.unsafeArgv,
            appLaunchOpts: nil
        )

        // Keep Flutter's window above Unity's window.
        if let window = framework.appController()?.window {
            window.windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue - 1)
        }

        stateLock.lock()
        _unityFramework = framework
        _isInitialized = true
        _isLoaded = true
        stateLock.unlock()

        startObservingAppLifecycle()

        NSLog("[UnityKit] Unity initialized")
        return true
    }

    // MARK: - Messaging

    /// Send a message to a Unity GameObject method.
    func sendMessage(gameObject: String, methodName: String, message: String) {
        stateLock.lock()
        guard let framework = _unityFramework, _isLoaded else {
            stateLock.unlock()
            NSLog("[UnityKit] Cannot send message - Unity not loaded")
            return
        }
        stateLock.unlock()

        framework.sendMessageToGO(
            withName: gameObject,
            functionName: methodName,
            message: message
        )
    }

    // MARK: - View

    /// Returns the Unity root view if available.
    func getView() -> UIView? {
        stateLock.lock()
        let framework = _unityFramework
        stateLock.unlock()

        return framework?.appController()?.rootView
    }

    /// Re-activate Unity's rendering surface after the view has been
    /// detached and reattached (e.g. Flutter navigation pop/push).
    ///
    /// Calls `showUnityWindow()` — the official Unity API for waking the
    /// render loop — and resets internal state so the player is considered
    /// active. Also forces Flutter's window level above Unity's.
    func restartRendering() {
        stateLock.lock()
        guard let framework = _unityFramework, _isInitialized else {
            stateLock.unlock()
            return
        }
        _isLoaded = true
        _isPaused = false
        stateLock.unlock()

        framework.showUnityWindow()

        // Ensure Flutter's window renders above Unity's.
        if let window = framework.appController()?.window {
            window.windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue - 1)
        }
    }

    /// Send Application.targetFrameRate to Unity via UnitySendMessage.
    func setTargetFrameRate(_ frameRate: Int) {
        sendMessage(gameObject: "FlutterBridge", methodName: "SetTargetFrameRate", message: "\(frameRate)")
        NSLog("[UnityKit] Set target frame rate: \(frameRate)")
    }

    // MARK: - Lifecycle

    /// Pause the Unity player.
    func pause() {
        stateLock.lock()
        guard let framework = _unityFramework, !_isPaused else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        framework.pause(true)

        stateLock.lock()
        _isPaused = true
        stateLock.unlock()
    }

    /// Resume the Unity player.
    func resume() {
        stateLock.lock()
        guard let framework = _unityFramework, _isPaused else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        framework.pause(false)

        stateLock.lock()
        _isPaused = false
        stateLock.unlock()
    }

    /// Unload Unity while keeping the process alive.
    func unload() {
        stateLock.lock()
        guard let framework = _unityFramework, _isLoaded else {
            stateLock.unlock()
            return
        }
        _isLoaded = false
        _isPaused = false
        stateLock.unlock()

        framework.unloadApplication()
        notifyListeners { $0.onUnloaded() }
        NSLog("[UnityKit] Unity unloaded")
    }

    /// Quit Unity completely. The player cannot be restarted after this.
    /// Checks `isInitialized` rather than just `unityFramework` (iOS-H5).
    func quit() {
        stateLock.lock()
        guard let framework = _unityFramework, _isInitialized else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        framework.quitApplication(0)
        cleanupState()
        NSLog("[UnityKit] Unity quit")
    }

    /// Release all resources. Call when the host app no longer needs Unity.
    func dispose() {
        stopObservingAppLifecycle()

        stateLock.lock()
        let framework = _unityFramework
        stateLock.unlock()

        if let framework = framework {
            framework.unregisterFrameworkListener(self)
        }

        cleanupState()
        NSLog("[UnityKit] Unity disposed")
    }

    // MARK: - Listener Management

    /// Register a listener for Unity events.
    func addListener(_ listener: UnityEventListener) {
        listenerLock.lock()
        defer { listenerLock.unlock() }

        // Avoid duplicate registrations.
        if !listeners.contains(where: { $0.value === listener }) {
            listeners.append(WeakListener(value: listener))
        }
    }

    /// Remove a previously registered listener.
    func removeListener(_ listener: UnityEventListener) {
        listenerLock.lock()
        defer { listenerLock.unlock() }

        listeners.removeAll { $0.value === listener }
    }

    // MARK: - Private Helpers

    private func loadFramework() -> UnityFramework? {
        let bundlePath = Bundle.main.bundlePath + "/Frameworks/UnityFramework.framework"
        guard let bundle = Bundle(path: bundlePath) else {
            NSLog("[UnityKit] UnityFramework bundle not found at: \(bundlePath)")
            return nil
        }

        if !bundle.isLoaded {
            bundle.load()
        }

        guard let framework = bundle.principalClass?.getInstance() as? UnityFramework else {
            NSLog("[UnityKit] Failed to obtain UnityFramework instance")
            return nil
        }

        return framework
    }

    /// Notify listeners of unload, then clear all state (iOS-M9).
    private func cleanupState() {
        notifyListeners { $0.onUnloaded() }

        stateLock.lock()
        _unityFramework = nil
        _isInitialized = false
        _isLoaded = false
        _isPaused = false
        stateLock.unlock()

        listenerLock.lock()
        listeners.removeAll()
        listenerLock.unlock()
    }

    private func notifyListeners(_ block: (UnityEventListener) -> Void) {
        listenerLock.lock()
        // Compact nil references while iterating.
        listeners.removeAll { $0.value == nil }
        let snapshot = listeners.compactMap { $0.value }
        listenerLock.unlock()

        for listener in snapshot {
            block(listener)
        }
    }

    // MARK: - App Lifecycle Observation

    private func startObservingAppLifecycle() {
        guard !isObservingAppLifecycle else { return }
        isObservingAppLifecycle = true

        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.willTerminateNotification,
            UIApplication.didReceiveMemoryWarningNotification,
        ]

        for name in names {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppLifecycle(_:)),
                name: name,
                object: nil
            )
        }
    }

    /// Remove only the specific notification observers we registered (iOS-M7).
    private func stopObservingAppLifecycle() {
        guard isObservingAppLifecycle else { return }
        isObservingAppLifecycle = false

        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.willTerminateNotification,
            UIApplication.didReceiveMemoryWarningNotification,
        ]
        for name in names {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    @objc private func handleAppLifecycle(_ notification: Notification) {
        stateLock.lock()
        guard _isInitialized else {
            stateLock.unlock()
            return
        }
        let framework = _unityFramework
        stateLock.unlock()

        let appController = framework?.appController()
        let application = UIApplication.shared

        switch notification.name {
        case UIApplication.willResignActiveNotification:
            appController?.applicationWillResignActive(application)
        case UIApplication.didEnterBackgroundNotification:
            appController?.applicationDidEnterBackground(application)
        case UIApplication.willEnterForegroundNotification:
            appController?.applicationWillEnterForeground(application)
        case UIApplication.didBecomeActiveNotification:
            appController?.applicationDidBecomeActive(application)
        case UIApplication.willTerminateNotification:
            appController?.applicationWillTerminate(application)
        case UIApplication.didReceiveMemoryWarningNotification:
            appController?.applicationDidReceiveMemoryWarning(application)
        default:
            break
        }
    }
}

// MARK: - UnityFrameworkListener

extension UnityPlayerManager: UnityFrameworkListener {

    func unityDidUnload(_ notification: Notification!) {
        stateLock.lock()
        _isLoaded = false
        _isPaused = false
        stateLock.unlock()

        notifyListeners { $0.onUnloaded() }
        NSLog("[UnityKit] Unity did unload (framework callback)")
    }

    func unityDidQuit(_ notification: Notification!) {
        cleanupState()
        NSLog("[UnityKit] Unity did quit (framework callback)")
    }
}

// MARK: - Message Forwarding

extension UnityPlayerManager {

    /// Forward a Unity message to all registered listeners.
    func forwardMessage(_ message: String) {
        notifyListeners { $0.onMessage(message) }
    }

    /// Forward a scene-loaded event to all registered listeners.
    func forwardSceneLoaded(
        name: String,
        buildIndex: Int32,
        isLoaded: Bool,
        isValid: Bool
    ) {
        notifyListeners {
            $0.onSceneLoaded(name, buildIndex: buildIndex, isLoaded: isLoaded, isValid: isValid)
        }
    }
}

// MARK: - WeakListener Wrapper

/// Weak wrapper to prevent retain cycles on listeners.
private final class WeakListener {
    weak var value: UnityEventListener?

    init(value: UnityEventListener) {
        self.value = value
    }
}

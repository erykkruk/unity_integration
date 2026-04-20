import Flutter
import UIKit

/// Platform view controller that bridges a single Flutter platform view
/// to the shared Unity player.
///
/// Each instance owns a `MethodChannel` named `com.unity_kit/unity_view_{viewId}`
/// and implements the same method contract as the Android side:
///
/// | Method                 | Return  |
/// |------------------------|---------|
/// | `unity#initialize`     | void    |
/// | `unity#createPlayer`   | void    |
/// | `unity#isReady`        | Bool    |
/// | `unity#isPaused`       | Bool    |
/// | `unity#isLoaded`       | Bool    |
/// | `unity#postMessage`    | void    |
/// | `unity#pausePlayer`    | void    |
/// | `unity#resumePlayer`   | void    |
/// | `unity#unloadPlayer`   | void    |
/// | `unity#quitPlayer`     | void    |
/// | `unity#dispose`        | void    |
///
/// Fixes applied:
/// - **Issue #2**: Linear backoff retry when waiting for Unity view.
/// - **Issue #6**: Message queue drains once the Flutter channel is ready.
public final class UnityKitViewController: NSObject, FlutterPlatformView, UnityEventListener {

    // MARK: - Constants

    private enum Defaults {
        static let maxRetryAttempts = 30
        static let baseRetryDelayMs = 100
        static let maxQueueSize = 100
    }

    // MARK: - Properties

    private let viewId: Int64
    private let channel: FlutterMethodChannel
    private let containerView: UnityKitView
    private var isDisposed = false

    // MARK: - Thread Safety (iOS-H2)

    private let disposeLock = NSLock()

    // MARK: - Retry Cancellation (iOS-M5)

    private var retryWorkItem: DispatchWorkItem?

    // MARK: - Message Queue (Issue #6)

    private var messageQueue: [(gameObject: String, methodName: String, message: String)] = []
    private var isChannelReady = false
    private let queueLock = NSLock()

    // MARK: - Init

    init(
        frame: CGRect,
        viewId: Int64,
        messenger: FlutterBinaryMessenger,
        args: Any?
    ) {
        self.viewId = viewId
        let transparentBackground =
            (args as? [String: Any])?["transparentBackground"] as? Bool ?? false
        self.containerView = UnityKitView(
            frame: frame,
            transparentBackground: transparentBackground
        )

        let channelName = "com.unity_kit/unity_view_\(viewId)"
        self.channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)

        super.init()

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }

        FlutterBridgeRegistry.register(viewId: Int(viewId), controller: self)
        UnityPlayerManager.shared.addListener(self)

        NSLog("[UnityKit] ViewController created: viewId=\(viewId)")

        // Auto-initialize Unity on creation (mirrors Android autoInitialize behavior).
        // Deferred until the container view has a non-zero layout, because Unity's
        // Metal renderer crashes (SIGABRT) if it creates textures with zero dimensions.
        waitForNonZeroFrame()
    }

    // MARK: - FlutterPlatformView

    public func view() -> UIView {
        return containerView
    }

    // MARK: - Auto Initialize (mirrors Android behavior)

    /// Polls until the container view has a non-zero frame, then initializes Unity.
    ///
    /// Unity's Metal renderer creates textures matching the root view size.
    /// If initialized before the platform view has layout, it gets a 0x0 frame
    /// and crashes with `MTLTextureDescriptor has width/height of zero`.
    private func waitForNonZeroFrame(attempt: Int = 0) {
        guard !isDisposed else { return }

        if !containerView.bounds.isEmpty {
            NSLog("[UnityKit] Container has frame: \(containerView.bounds), starting auto-init")
            autoInitialize()
        } else if attempt < 20 {
            // Poll every 50ms for up to 1 second.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.waitForNonZeroFrame(attempt: attempt + 1)
            }
        } else {
            NSLog("[UnityKit] Container still zero-sized after 1s, starting auto-init anyway")
            autoInitialize()
        }
    }

    /// Automatically initializes Unity and attaches the view.
    ///
    /// On Android this happens in `autoInitialize()` called from `init`.
    /// On iOS we mirror the same behavior: initialize the framework if needed,
    /// then wait for the Unity view to become available.
    private func autoInitialize() {
        guard !isDisposed else { return }

        let manager = UnityPlayerManager.shared

        if !manager.isInitialized {
            let success = manager.initialize()
            if !success {
                sendEvent(name: "onError", data: ["message": "Failed to initialize Unity framework"])
                return
            }
        }

        // Wait for the Unity view with linear backoff retry.
        waitForUnityView(attempt: 0, maxAttempts: Defaults.maxRetryAttempts)
    }

    // MARK: - Method Channel Handler

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard !isDisposed else {
            result(
                FlutterError(
                    code: "DISPOSED",
                    message: "View \(viewId) has been disposed",
                    details: nil
                )
            )
            return
        }

        switch call.method {
        case "unity#initialize":
            handleInitialize(result: result)
        case "unity#createPlayer":
            handleCreatePlayer(result: result)
        case "unity#isReady":
            result(UnityPlayerManager.shared.isInitialized)
        case "unity#isPaused":
            result(UnityPlayerManager.shared.isPaused)
        case "unity#isLoaded":
            result(UnityPlayerManager.shared.isLoaded)
        case "unity#postMessage":
            handlePostMessage(call: call, result: result)
        case "unity#pausePlayer":
            UnityPlayerManager.shared.pause()
            result(nil)
        case "unity#resumePlayer":
            UnityPlayerManager.shared.resume()
            result(nil)
        case "unity#unloadPlayer":
            UnityPlayerManager.shared.unload()
            result(nil)
        case "unity#quitPlayer":
            UnityPlayerManager.shared.quit()
            result(nil)
        case "unity#dispose":
            dispose()
            result(nil)
        case "unity#setTargetFrameRate":
            handleSetTargetFrameRate(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Implementations

    /// Initialize Unity. Sends error event to Dart on failure (iOS-H4).
    private func handleInitialize(result: @escaping FlutterResult) {
        let success = UnityPlayerManager.shared.initialize()
        if !success {
            result(
                FlutterError(
                    code: "INIT_FAILED",
                    message: "Failed to initialize Unity framework",
                    details: nil
                )
            )
            return
        }
        result(nil)
    }

    /// Create and attach the Unity player. Sends error event to Dart on failure (iOS-H4).
    private func handleCreatePlayer(result: @escaping FlutterResult) {
        let manager = UnityPlayerManager.shared

        if !manager.isInitialized {
            let success = manager.initialize()
            if !success {
                result(
                    FlutterError(
                        code: "INIT_FAILED",
                        message: "Failed to initialize Unity framework",
                        details: nil
                    )
                )
                return
            }
        }

        // Wait for the Unity view with linear backoff (Issue #2).
        waitForUnityView(attempt: 0, maxAttempts: Defaults.maxRetryAttempts)
        result(nil)
    }

    /// Route through `enqueueOrSend` instead of sending directly (iOS-C4).
    private func handlePostMessage(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let gameObject = args["gameObject"] as? String,
              let methodName = args["methodName"] as? String,
              let message = args["message"] as? String
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGS",
                    message: "postMessage requires gameObject, methodName, message",
                    details: nil
                )
            )
            return
        }

        enqueueOrSend(gameObject: gameObject, methodName: methodName, message: message)
        result(nil)
    }

    private func handleSetTargetFrameRate(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let frameRate = args["frameRate"] as? Int,
              frameRate > 0
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGS",
                    message: "frameRate must be a positive integer",
                    details: nil
                )
            )
            return
        }
        UnityPlayerManager.shared.setTargetFrameRate(frameRate)
        result(nil)
    }

    // MARK: - Unity View Attachment (Issue #2)

    /// Wait for the Unity root view with linear backoff.
    ///
    /// Delay = `baseRetryDelayMs * (attempt + 1)`, so:
    /// 100ms, 200ms, 300ms, ... up to `maxAttempts`.
    private func waitForUnityView(attempt: Int, maxAttempts: Int) {
        guard !isDisposed else { return }

        // Wait for container to have a non-zero frame before attaching.
        // Unity's Metal renderer creates textures matching the view size;
        // a zero-sized frame causes SIGABRT (MTLTextureDescriptor width/height of zero).
        guard !containerView.bounds.isEmpty else {
            if attempt < maxAttempts {
                let delayMs = Defaults.baseRetryDelayMs * (attempt + 1)
                let workItem = DispatchWorkItem { [weak self] in
                    self?.waitForUnityView(attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                retryWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: workItem)
            } else {
                NSLog("[UnityKit] Container still zero-sized after \(maxAttempts) attempts: viewId=\(viewId)")
                sendEvent(name: "onError", data: ["message": "Container view has zero size"])
            }
            return
        }

        if let unityView = UnityPlayerManager.shared.getView() {
            containerView.attachUnityView(unityView)

            // Wake up Unity's render loop after reattachment — subsystems like
            // AR (Vuforia) need an explicit restart after detach/reattach.
            UnityPlayerManager.shared.restartRendering()

            markChannelReady()
            sendEvent(name: "onUnityCreated", data: nil)
            NSLog("[UnityKit] Unity view attached: viewId=\(viewId)")
        } else if attempt < maxAttempts {
            // Linear backoff: delay increases linearly with each attempt (iOS-M3).
            let delayMs = Defaults.baseRetryDelayMs * (attempt + 1)
            let workItem = DispatchWorkItem { [weak self] in
                self?.waitForUnityView(attempt: attempt + 1, maxAttempts: maxAttempts)
            }
            retryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: workItem)
        } else {
            NSLog("[UnityKit] Unity view not available after \(maxAttempts) attempts: viewId=\(viewId)")
            sendEvent(name: "onError", data: ["message": "Unity view not available"])
        }
    }

    // MARK: - Message Queue (Issue #6)

    /// Mark the channel as ready and drain all queued messages.
    private func markChannelReady() {
        queueLock.lock()
        isChannelReady = true
        let pending = messageQueue
        messageQueue.removeAll()
        queueLock.unlock()

        if !pending.isEmpty {
            NSLog("[UnityKit] Flushing \(pending.count) queued messages: viewId=\(viewId)")
        }

        for msg in pending {
            UnityPlayerManager.shared.sendMessage(
                gameObject: msg.gameObject,
                methodName: msg.methodName,
                message: msg.message
            )
        }
    }

    /// Enqueue a message if the channel is not yet ready; send immediately otherwise.
    private func enqueueOrSend(gameObject: String, methodName: String, message: String) {
        queueLock.lock()

        if isChannelReady {
            queueLock.unlock()
            UnityPlayerManager.shared.sendMessage(
                gameObject: gameObject,
                methodName: methodName,
                message: message
            )
        } else {
            messageQueue.append((gameObject, methodName, message))
            // Cap the queue to prevent unbounded growth.
            if messageQueue.count > Defaults.maxQueueSize {
                messageQueue.removeFirst()
                NSLog("[UnityKit] Message queue overflow, oldest message dropped: viewId=\(viewId)")
            }
            queueLock.unlock()
        }
    }

    // MARK: - Event Sending

    /// Send an event to the Flutter side via the MethodChannel.
    private func sendEvent(name: String, data: Any?) {
        guard !isDisposed else { return }

        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod(name, arguments: data)
        }
    }

    // MARK: - UnityEventListener

    func onMessage(_ message: String) {
        sendEvent(name: "onUnityMessage", data: message)
    }

    func onSceneLoaded(_ name: String, buildIndex: Int32, isLoaded: Bool, isValid: Bool) {
        sendEvent(name: "onUnitySceneLoaded", data: [
            "name": name,
            "buildIndex": buildIndex,
            "isLoaded": isLoaded,
            "isValid": isValid,
        ])
    }

    func onCreated() {
        sendEvent(name: "onUnityCreated", data: nil)
    }

    func onUnloaded() {
        sendEvent(name: "onUnityUnloaded", data: nil)
    }

    // MARK: - Dispose

    /// Thread-safe dispose with double-dispose guard (iOS-H2).
    private func dispose() {
        disposeLock.lock()
        guard !isDisposed else {
            disposeLock.unlock()
            return
        }
        isDisposed = true
        disposeLock.unlock()

        // Cancel any pending retry work item (iOS-M5).
        retryWorkItem?.cancel()
        retryWorkItem = nil

        UnityPlayerManager.shared.removeListener(self)
        FlutterBridgeRegistry.unregister(viewId: Int(viewId))

        channel.setMethodCallHandler(nil)
        containerView.detachUnityView()

        queueLock.lock()
        messageQueue.removeAll()
        queueLock.unlock()

        NSLog("[UnityKit] ViewController disposed: viewId=\(viewId)")
    }

    deinit {
        dispose()
    }
}

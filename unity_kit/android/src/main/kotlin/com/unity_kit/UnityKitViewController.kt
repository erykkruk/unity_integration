package com.unity_kit

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

/// Controller for a single Unity PlatformView instance.
///
/// Manages the MethodChannel per view, forwards touch events to Unity,
/// handles lifecycle callbacks, and routes Unity events back to Flutter.
///
/// Key design decisions:
/// - HybridComposition rendering mode by default (Issue #4 fix)
/// - Retry with [Handler.postDelayed] for view reattachment (Issue #2 fix)
/// - Main thread event forwarding via [Handler(Looper.getMainLooper())]
/// - Uses activity provider instead of direct reference to avoid stale Activity (AND-H2)
class UnityKitViewController(
    private val context: Context,
    private val viewId: Int,
    messenger: BinaryMessenger,
    private val config: Map<String, Any?>,
    private val activityProvider: () -> Activity?,
) : PlatformView, DefaultLifecycleObserver, MethodChannel.MethodCallHandler, UnityEventListener {

    companion object {
        private const val TAG = "UnityKitViewController"
        private const val CHANNEL_PREFIX = "com.unity_kit/unity_view_"
        private const val VIEW_REATTACH_DELAY_MS = 200L
        private const val MAX_REATTACH_ATTEMPTS = 10
    }

    private val methodChannel = MethodChannel(messenger, "$CHANNEL_PREFIX$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val containerView = object : FrameLayout(context) {
        init { setBackgroundColor(Color.TRANSPARENT) }

        override fun onWindowVisibilityChanged(visibility: Int) {
            // When the view becomes visible after a GONE→VISIBLE transition
            // (hot reload, orientation change, widget rebuild), Unity UI freezes.
            // Pause + resume unfreezes it. Pattern from flutter_embed_unity.
            if (visibility == View.VISIBLE && !isDisposed) {
                Log.d(TAG, "Container became visible, refreshing Unity rendering")
                UnityPlayerManager.refreshRendering()
            }
            super.onWindowVisibilityChanged(visibility)
        }

        override fun dispatchTouchEvent(motionEvent: MotionEvent): Boolean {
            // Flutter Virtual Display creates touch events with deviceId=0.
            // Unity's New Input System ignores deviceId=0 touches.
            // Copy the event with deviceId=-1 so Unity detects the touch.
            // Pattern from flutter_embed_unity (CopyMotionEvent / CustomFrameLayout).
            motionEvent.source = InputDevice.SOURCE_TOUCHSCREEN
            if (motionEvent.deviceId == 0) {
                val modified = motionEvent.copyWithDeviceId(deviceId = -1)
                motionEvent.recycle()
                return super.dispatchTouchEvent(modified)
            }
            return super.dispatchTouchEvent(motionEvent)
        }
    }
    private var isDisposed = false
    private var isAttached = false
    private var reattachAttempts = 0

    /// Lifecycle reference for cleanup during dispose.
    var lifecycle: Lifecycle? = null

    init {
        methodChannel.setMethodCallHandler(this)
        FlutterBridgeRegistry.register(viewId, this)
        UnityPlayerManager.addListener(this)

        // Defer auto-init to next main thread cycle so activity binding is available.
        mainHandler.post { autoInitialize() }

        Log.d(TAG, "ViewController created for viewId=$viewId")
    }

    private fun autoInitialize() {
        if (isDisposed) return

        val currentActivity = activityProvider()
        Log.d(TAG, "Auto-init: activity=${currentActivity != null}, isReady=${UnityPlayerManager.isReady}")

        if (currentActivity != null && !UnityPlayerManager.isReady) {
            try {
                UnityPlayerManager.createPlayer(currentActivity)
                Log.i(TAG, "Auto-init: Unity player created successfully")
                applyTargetFrameRate()
            } catch (e: Exception) {
                Log.e(TAG, "Auto-init: failed to create Unity player", e)
            }
        }

        attachUnityView()
    }

    /// Sends the configured targetFrameRate to Unity via UnitySendMessage.
    ///
    /// Reads from creation params and sends to FlutterBridge.SetTargetFrameRate.
    /// No-op if targetFrameRate is not in config or player is not ready.
    private fun applyTargetFrameRate() {
        val frameRate = (config["targetFrameRate"] as? Number)?.toInt() ?: return
        if (frameRate > 0) {
            UnityPlayerManager.setTargetFrameRate(frameRate)
        }
    }

    // --- PlatformView ---

    override fun getView(): View = containerView

    override fun dispose() {
        if (isDisposed) return
        isDisposed = true

        mainHandler.removeCallbacksAndMessages(null)
        lifecycle?.removeObserver(this)

        methodChannel.setMethodCallHandler(null)
        FlutterBridgeRegistry.unregister(viewId)
        UnityPlayerManager.removeListener(this)
        detachUnityView()

        Log.d(TAG, "ViewController disposed for viewId=$viewId")
    }

    // --- DefaultLifecycleObserver ---

    override fun onResume(owner: LifecycleOwner) {
        if (isDisposed) return
        // Force pause+resume cycle to unfreeze Unity UI after activity resume.
        // Just calling resume() is insufficient when Unity appears frozen without
        // the internal isPaused flag reflecting it (e.g., after permission dialogs).
        UnityPlayerManager.refreshRendering()
    }

    override fun onPause(owner: LifecycleOwner) {
        if (isDisposed) return
        UnityPlayerManager.pause()
    }

    override fun onDestroy(owner: LifecycleOwner) {
        dispose()
    }

    // --- MethodChannel.MethodCallHandler ---

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (isDisposed) {
            result.error("DISPOSED", "ViewController is disposed", null)
            return
        }

        when (call.method) {
            "unity#createPlayer" -> handleCreatePlayer(call, result)
            "unity#postMessage" -> handlePostMessage(call, result)
            "unity#isReady" -> result.success(UnityPlayerManager.isReady)
            "unity#isPaused" -> result.success(UnityPlayerManager.playerIsPaused)
            "unity#isLoaded" -> result.success(UnityPlayerManager.playerIsLoaded)
            "unity#pausePlayer" -> handlePausePlayer(result)
            "unity#resumePlayer" -> handleResumePlayer(result)
            "unity#unloadPlayer" -> handleUnloadPlayer(result)
            "unity#quitPlayer" -> handleQuitPlayer(result)
            "unity#dispose" -> handleDispose(result)
            "unity#initialize" -> handleInitialize(call, result)
            "unity#setTargetFrameRate" -> handleSetTargetFrameRate(call, result)
            else -> result.notImplemented()
        }
    }

    // --- Method Handlers ---

    private fun handleCreatePlayer(call: MethodCall, result: MethodChannel.Result) {
        val currentActivity = activityProvider()
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "No activity available to create Unity player", null)
            return
        }

        try {
            UnityPlayerManager.createPlayer(currentActivity)
            attachUnityView()
            result.success(null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", "Failed to create Unity player: ${e.message}", null)
        }
    }

    private fun handlePostMessage(call: MethodCall, result: MethodChannel.Result) {
        val gameObject = call.argument<String>("gameObject")
        val methodName = call.argument<String>("methodName")
        val message = call.argument<String>("message") ?: ""

        if (gameObject == null || methodName == null) {
            result.error(
                "INVALID_ARGS",
                "gameObject and methodName are required",
                null,
            )
            return
        }

        UnityPlayerManager.sendMessage(gameObject, methodName, message)
        result.success(null)
    }

    private fun handlePausePlayer(result: MethodChannel.Result) {
        UnityPlayerManager.pause()
        result.success(null)
    }

    private fun handleResumePlayer(result: MethodChannel.Result) {
        UnityPlayerManager.resume()
        result.success(null)
    }

    private fun handleUnloadPlayer(result: MethodChannel.Result) {
        UnityPlayerManager.unload()
        result.success(null)
    }

    private fun handleQuitPlayer(result: MethodChannel.Result) {
        detachUnityView()
        UnityPlayerManager.quit()
        result.success(null)
    }

    private fun handleDispose(result: MethodChannel.Result) {
        dispose()
        result.success(null)
    }

    private fun handleSetTargetFrameRate(call: MethodCall, result: MethodChannel.Result) {
        val frameRate = call.argument<Int>("frameRate")
        if (frameRate == null || frameRate <= 0) {
            result.error("INVALID_ARGS", "frameRate must be a positive integer", null)
            return
        }
        UnityPlayerManager.setTargetFrameRate(frameRate)
        result.success(null)
    }

    private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
        val currentActivity = activityProvider()
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "No activity available for initialization", null)
            return
        }

        try {
            if (!UnityPlayerManager.isReady) {
                UnityPlayerManager.createPlayer(currentActivity)
            }
            attachUnityView()
            result.success(null)
        } catch (e: Exception) {
            result.error("INIT_FAILED", "Failed to initialize Unity player: ${e.message}", null)
        }
    }

    // --- UnityEventListener ---

    override fun onMessage(message: String) {
        invokeOnMainThread("onUnityMessage", message)
    }

    override fun onSceneLoaded(name: String, buildIndex: Int, isLoaded: Boolean, isValid: Boolean) {
        val args = mapOf(
            "name" to name,
            "buildIndex" to buildIndex,
            "isLoaded" to isLoaded,
            "isValid" to isValid,
        )
        invokeOnMainThread("onUnitySceneLoaded", args)
    }

    override fun onCreated() {
        invokeOnMainThread("onUnityCreated", null)
        // Attempt to attach the view now that the player is created
        mainHandler.post { attachUnityView() }
    }

    override fun onUnloaded() {
        invokeOnMainThread("onUnityUnloaded", null)
    }

    // --- View Management ---

    /// Attaches the Unity player view to the container FrameLayout.
    ///
    /// Includes retry logic with [Handler.postDelayed] for cases where
    /// the view is temporarily unavailable during navigation (Issue #2 fix).
    /// Applies refocus pattern after attachment (AND-C1) and touch source fix (AND-C2).
    /// Uses transparent background + z-order + Choreographer invalidation (reference lib pattern).
    private fun attachUnityView() {
        if (isDisposed) return

        // Prevent double attachment which causes surface destroy/recreate cycle
        if (isAttached && containerView.childCount > 0) {
            Log.d(TAG, "Unity view already attached, skipping")
            UnityPlayerManager.focus()
            return
        }

        val unityView = UnityPlayerManager.getView()
        if (unityView == null) {
            if (reattachAttempts < MAX_REATTACH_ATTEMPTS) {
                reattachAttempts++
                Log.d(TAG, "Unity view not available, retry $reattachAttempts/$MAX_REATTACH_ATTEMPTS")
                mainHandler.postDelayed({ attachUnityView() }, VIEW_REATTACH_DELAY_MS)
            } else {
                Log.w(TAG, "Unity view not available after $MAX_REATTACH_ATTEMPTS attempts")
                reattachAttempts = 0
            }
            return
        }

        reattachAttempts = 0

        // Remove all existing children before adding Unity view
        containerView.removeAllViews()

        containerView.addView(
            unityView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Fix Android display bug: Unity's SurfaceView renders on top of all
        // Flutter widgets by default, ignoring widget bounds and z-ordering.
        // Setting setZOrderOnTop(false) forces it to render within its container.
        applyZOrderFix(unityView)

        isAttached = true

        // Activate Unity rendering: windowFocusChanged + pause/resume
        UnityPlayerManager.focus()

        // Force layout pass
        containerView.requestLayout()

        // Delayed re-activation for Hybrid Composition mode.
        // HC manages the view hierarchy differently than Virtual Display;
        // the initial focus() may fire before HC finishes surface setup.
        // A delayed re-focus ensures rendering starts after HC is ready.
        mainHandler.postDelayed({
            if (!isDisposed && isAttached) {
                UnityPlayerManager.focus()
                containerView.invalidate()
            }
        }, 500)

        Log.d(TAG, "Unity view attached to container for viewId=$viewId")
    }

    /// Detaches the Unity view from the container without destroying it.
    private fun detachUnityView() {
        containerView.setOnTouchListener(null)
        containerView.removeAllViews()
        isAttached = false
    }

    /// Fixes Unity's SurfaceView Z-order so it renders within its container
    /// instead of floating on top of all Flutter widgets (Issue #1).
    private fun applyZOrderFix(view: View) {
        val surfaceView = findSurfaceView(view)
        if (surfaceView != null) {
            surfaceView.setZOrderOnTop(false)
            surfaceView.setZOrderMediaOverlay(false)
            Log.d(TAG, "Applied Z-order fix to SurfaceView")
        } else {
            Log.d(TAG, "No SurfaceView found in Unity view hierarchy, Z-order fix skipped")
        }
    }

    /// Recursively searches for a [SurfaceView] in the view hierarchy.
    private fun findSurfaceView(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findSurfaceView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    // --- Touch Fix (AND-C2) ---

    /// Copies a [MotionEvent] with a different deviceId.
    ///
    /// MotionEvent.deviceId is immutable, so we recreate the event using [MotionEvent.obtain]
    /// with all original properties but the new deviceId. This is needed because Flutter
    /// Virtual Display creates touch events with deviceId=0, which Unity's New Input System
    /// ignores. Pattern from flutter_embed_unity (CopyMotionEvent.kt).
    private fun MotionEvent.copyWithDeviceId(deviceId: Int): MotionEvent {
        val pointerCount = this.pointerCount
        val pointerProperties = Array(pointerCount) { i ->
            MotionEvent.PointerProperties().also { this.getPointerProperties(i, it) }
        }
        val pointerCoords = Array(pointerCount) { i ->
            MotionEvent.PointerCoords().also { this.getPointerCoords(i, it) }
        }
        return MotionEvent.obtain(
            this.downTime,
            this.eventTime,
            this.action,
            pointerCount,
            pointerProperties,
            pointerCoords,
            this.metaState,
            this.buttonState,
            this.xPrecision,
            this.yPrecision,
            deviceId,
            this.edgeFlags,
            this.source,
            this.flags,
        )
    }

    // --- MethodChannel Helpers ---

    /// Invokes a Flutter MethodChannel callback on the main thread.
    private fun invokeOnMainThread(method: String, arguments: Any?) {
        if (isDisposed) return

        mainHandler.post {
            if (!isDisposed) {
                try {
                    methodChannel.invokeMethod(method, arguments)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to invoke $method on Flutter", e)
                }
            }
        }
    }
}

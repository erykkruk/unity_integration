# Android Integration Guide -- Unity 6000 Patterns

This document captures critical findings from debugging the Android native integration layer for `unity_kit`, specifically the patterns required for Unity 6000 (Unity 6) compatibility.

**Reference library:** [flutter_embed_unity](https://github.com/nickmeinhold/flutter_embed_unity) -- has a separate Unity 6000 Android implementation that served as the architectural pattern for several of these solutions.

---

## Table of Contents

- [Unity 6000 Player Changes](#unity-6000-player-changes)
- [Player Creation via Reflection](#player-creation-via-reflection)
- [View Embedding Pattern](#view-embedding-pattern)
- [Rendering Activation](#rendering-activation)
- [Container FrameLayout](#container-framelayout)
- [PlatformView Mode (Dart Side)](#platformview-mode-dart-side)
- [Double Attachment Prevention](#double-attachment-prevention)
- [Auto-initialization](#auto-initialization)
- [Touch Events](#touch-events)
- [C# Bridge Scripts](#c-bridge-scripts)
- [ProGuard / R8 Rules](#proguard--r8-rules)
- [Complete Integration Flow](#complete-integration-flow)
- [Known Issues and Workarounds](#known-issues-and-workarounds)

---

## Unity 6000 Player Changes

Unity 6000 introduced a breaking change to the Android player class:

| Unity Version | Class | Extends | Constructor |
|---------------|-------|---------|-------------|
| 2019-2022.3 | `com.unity3d.player.UnityPlayer` | `FrameLayout` | `UnityPlayer(Activity)` |
| 6000+ | `com.unity3d.player.UnityPlayerForActivityOrService` | **Does NOT extend FrameLayout** | `UnityPlayerForActivityOrService(Context, IUnityPlayerLifecycleEvents?)` |

The critical difference: `UnityPlayerForActivityOrService` is no longer a `View`. You cannot add it directly to a view hierarchy. Instead, you must call `getFrameLayout()` to obtain the embeddable `View`.

---

## Player Creation via Reflection

The native Android layer uses reflection to support both Unity 6 and legacy Unity versions without compile-time dependencies.

### Strategy

Try Unity 6 class first, then fall back to legacy:

```kotlin
private fun createPlayerViaReflection(activity: Activity): Any {
    // 1. Try Unity 6 class
    val clazz = try {
        Class.forName("com.unity3d.player.UnityPlayerForActivityOrService")
    } catch (_: ClassNotFoundException) {
        // 2. Fall back to legacy class
        Class.forName("com.unity3d.player.UnityPlayer")
    }

    // 3. Try multiple constructor signatures (most specific first)
    return tryConstructors(clazz, activity)
}
```

### Constructor signatures to attempt

The following constructor signatures should be attempted in order:

```kotlin
private fun tryConstructors(clazz: Class<*>, activity: Activity): Any {
    // Signature 1: Unity 6 with lifecycle events
    try {
        val lifecycleClass = Class.forName(
            "com.unity3d.player.IUnityPlayerLifecycleEvents"
        )
        return clazz.getConstructor(Context::class.java, lifecycleClass)
            .newInstance(activity, null)
    } catch (_: Exception) {}

    // Signature 2: Unity 6 with Context only
    try {
        return clazz.getConstructor(Context::class.java)
            .newInstance(activity)
    } catch (_: Exception) {}

    // Signature 3: Legacy with Activity
    try {
        return clazz.getConstructor(Activity::class.java)
            .newInstance(activity)
    } catch (_: Exception) {}

    throw IllegalStateException("No compatible Unity player constructor found")
}
```

**Important:** Catch `Throwable` (not just `Exception`) because `UnsatisfiedLinkError` extends `Error`, not `Exception`. If Unity native libraries are corrupted or missing, this error will be thrown from the constructor.

---

## View Embedding Pattern

### Extracting the embeddable View

For Unity 6, the player object is not a `View`. You must extract the embeddable view:

```kotlin
private fun getEmbeddableView(player: Any): View {
    // Unity 6: use getFrameLayout()
    try {
        val frameLayout = player.javaClass
            .getMethod("getFrameLayout")
            .invoke(player) as? View
        if (frameLayout != null) return frameLayout
    } catch (_: Exception) {}

    // Additional fallback methods to try
    val fallbackMethods = listOf(
        "getView",
        "getPlayerView",
        "getSurfaceView",
        "getRootView",
    )
    for (methodName in fallbackMethods) {
        try {
            val view = player.javaClass
                .getMethod(methodName)
                .invoke(player) as? View
            if (view != null) return view
        } catch (_: Exception) { continue }
    }

    // Last resort: player itself if it is a View (legacy UnityPlayer)
    if (player is View) return player

    throw IllegalStateException("Cannot extract View from Unity player")
}
```

### Adding to container

Once you have the embeddable view, detach it from any existing parent and add it to your container `FrameLayout`:

```kotlin
private fun attachToContainer(unityView: View, container: FrameLayout) {
    // Detach from current parent if any
    (unityView.parent as? ViewGroup)?.removeView(unityView)

    // Add to container with MATCH_PARENT
    container.addView(
        unityView,
        FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
    )
}
```

---

## Rendering Activation

After attaching the Unity view to the container, Unity's rendering pipeline must be explicitly activated. Without this step, the user sees a black or frozen screen.

### The refocus pattern

```kotlin
private fun activateRendering(player: Any, unityView: View) {
    // 1. Signal window focus to the player
    try {
        val focusResult = unityView.requestFocus()
        player.javaClass
            .getMethod("windowFocusChanged", Boolean::class.java)
            .invoke(player, focusResult)
    } catch (_: Exception) {}

    // 2. Pause then resume to unfreeze the rendering pipeline
    try {
        player.javaClass.getMethod("pause").invoke(player)
        player.javaClass.getMethod("resume").invoke(player)
    } catch (_: Exception) {}
}
```

**Why this works:** The `windowFocusChanged(true)` call tells the Unity player that it has gained focus, which initializes the rendering surface. The `pause()` + `resume()` cycle forces the rendering pipeline to restart, which clears any frozen frame state.

Both reference libraries (`flutter_unity_widget` and `flutter_embed_unity`) require this pattern. Without it, the Unity view renders a black screen.

---

## Container FrameLayout

The container `FrameLayout` that hosts the Unity view must override `onWindowVisibilityChanged` to handle orientation changes and hot reloads:

```kotlin
class UnityContainerLayout(context: Context) : FrameLayout(context) {

    private var player: Any? = null

    fun setPlayer(player: Any) {
        this.player = player
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)

        if (visibility == VISIBLE) {
            // When becoming visible again (after orientation change,
            // hot reload, or returning from background), restart
            // rendering to prevent UI freeze.
            player?.let { p ->
                try {
                    p.javaClass.getMethod("pause").invoke(p)
                    p.javaClass.getMethod("resume").invoke(p)
                } catch (_: Exception) {}
            }
        }
    }
}
```

**Why this is needed:** When the Activity undergoes a configuration change (orientation change) or when Flutter hot-reloads, the Unity rendering can freeze. The `pause()` + `resume()` cycle in `onWindowVisibilityChanged(VISIBLE)` restarts the rendering pipeline.

---

## PlatformView Mode (Dart Side)

On the Dart/Flutter side, use `PlatformViewLink` + `initExpensiveAndroidView` (Hybrid Composition) to embed the native Unity view:

```dart
// Correct: Hybrid Composition via PlatformViewLink
PlatformViewLink(
  viewType: 'com.unity_kit/unity_view',
  surfaceFactory: (context, controller) {
    return AndroidViewSurface(
      controller: controller as AndroidViewController,
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      gestureRecognizers: gestureRecognizers,
    );
  },
  onCreatePlatformView: (params) {
    return PlatformViewsService.initExpensiveAndroidView(
      id: params.id,
      viewType: viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
    )
      ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
      ..create();
  },
)
```

**Do NOT use `AndroidView` (Virtual Display mode):**

```dart
// WRONG: Unity SurfaceView renders on top of all Flutter widgets
AndroidView(
  viewType: 'com.unity_kit/unity_view',
  creationParams: config.toMap(),
  creationParamsCodec: const StandardMessageCodec(),
)
```

Virtual Display renders the native view into an offscreen texture, but Unity's `SurfaceView` bypasses this and creates its own window surface directly on screen. This causes the Unity view to cover all Flutter content regardless of layout bounds ([#1](https://github.com/erykkruk/flutter_unity_kit/issues/1)).

Hybrid Composition places the native view directly in the Android view hierarchy, which correctly respects z-ordering and widget bounds. A delayed re-focus (500ms post-attachment) ensures Unity's rendering pipeline activates after HC finishes surface setup.

---

## Double Attachment Prevention

Track an `isAttached` flag to prevent the Unity view from being destroyed and recreated when Flutter's Virtual Display mode triggers surface destroy/recreate cycles:

```kotlin
class UnityKitViewController(...) {
    private var isAttached = false

    private fun attachUnityView() {
        if (isAttached) return  // Prevent double attachment

        val unityView = getEmbeddableView(player)
        attachToContainer(unityView, containerView)
        activateRendering(player, unityView)
        isAttached = true
    }

    private fun detachUnityView() {
        if (!isAttached) return

        containerView.removeAllViews()
        isAttached = false
    }
}
```

Without this guard, the platform view framework can trigger multiple attach/detach cycles, each of which causes a visible flicker or rendering interruption.

---

## Auto-initialization

Defer Unity player initialization using `Handler.postDelayed` to avoid race conditions with Activity binding:

```kotlin
private val mainHandler = Handler(Looper.getMainLooper())

fun onCreate() {
    // Defer initialization to let the Activity fully bind
    mainHandler.postDelayed({
        if (!isDisposed) {
            initializeUnityPlayer()
        }
    }, AUTO_INIT_DELAY_MS)
}

companion object {
    private const val AUTO_INIT_DELAY_MS = 100L
}
```

**Why this is needed:** When the platform view is created, the Activity may not be fully bound to the window yet. Attempting to create the Unity player immediately can fail silently or crash. The delay allows the Activity lifecycle to complete before Unity initialization begins.

**Important:** Cancel pending callbacks on dispose:

```kotlin
fun dispose() {
    mainHandler.removeCallbacksAndMessages(null)
    // ... rest of cleanup
}
```

---

## Touch Events

### Problem

Flutter's Virtual Display mode forwards touch events with `deviceId = 0`. Unity's New Input System does not recognize these events because it expects a specific device ID.

### Solution

Override `dispatchTouchEvent` on the container and fix the `deviceId`:

```kotlin
class UnityContainerLayout(context: Context) : FrameLayout(context) {

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // Flutter's Virtual Display sends events with deviceId = 0.
        // Unity's New Input System requires deviceId != 0 to register touch.
        // Copy the event with deviceId = -1 to make Unity recognize it.
        val fixedEvent = if (event.deviceId == 0) {
            MotionEvent.obtain(event).apply {
                // Use reflection or MotionEvent.obtain with modified deviceId
                try {
                    val field = MotionEvent::class.java.getDeclaredField("mDeviceId")
                    field.isAccessible = true
                    field.setInt(this, -1)
                } catch (_: Exception) {
                    // Fallback: use the event as-is
                }
            }
        } else {
            event
        }

        // Also ensure the event source is set correctly
        fixedEvent.source = InputDevice.SOURCE_TOUCHSCREEN

        return super.dispatchTouchEvent(fixedEvent)
    }
}
```

**Alternative approach (simpler but less robust):**

```kotlin
containerView.setOnTouchListener { _, event ->
    event.source = InputDevice.SOURCE_TOUCHSCREEN
    unityView.dispatchTouchEvent(event)
}
```

The `InputDevice.SOURCE_TOUCHSCREEN` source type is required because Unity's New Input System uses the event source to determine input type. Without it, touch events are ignored.

---

## C# Bridge Scripts

### FlutterBridge.cs

The main bridge script auto-creates itself and handles communication:

```csharp
using UnityEngine;

namespace UnityKit
{
    public class FlutterBridge : MonoBehaviour
    {
        public static FlutterBridge Instance { get; private set; }

        public bool sendReadyOnStart = true;

        // Events
        public System.Action<string, string, string> OnFlutterMessage;
        public System.Action OnReady;

        // Two message formats supported:
        // 1. Typed: {"type":"command","data":{"key":"value"}}
        // 2. Routed: {"target":"GameManager","method":"StartGame","data":"params"}

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void AutoCreate()
        {
            if (Instance == null)
            {
                var go = new GameObject("FlutterBridge");
                go.AddComponent<FlutterBridge>();
                DontDestroyOnLoad(go);
            }
        }

        void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Destroy(gameObject);
                return;
            }
            Instance = this;
            DontDestroyOnLoad(gameObject);
        }

        void Start()
        {
            if (sendReadyOnStart)
                SendReady();
        }

        // Called by Flutter via UnitySendMessage
        public void ReceiveMessage(string json)
        {
            // Try routed format first
            var msg = JsonUtility.FromJson<FlutterMessage>(json);
            if (!string.IsNullOrEmpty(msg.target))
            {
                MessageRouter.Route(msg.target, msg.method, msg.data);
                OnFlutterMessage?.Invoke(msg.target, msg.method, msg.data);
            }
            // Typed format handled by OnTypedMessage subscribers
        }

        public void SendReady()
        {
            NativeAPI.SendToFlutter("{\"type\":\"ready\"}");
            OnReady?.Invoke();
        }
    }
}
```

**Key points:**
- Auto-creates via `[RuntimeInitializeOnLoadMethod]` -- no manual GameObject setup needed (though manual setup is recommended for Inspector control)
- Supports two message formats: **typed** (`{"type":"...","data":{...}}`) and **routed** (`{"target":"...","method":"...","data":"..."}`)
- Uses `DontDestroyOnLoad` to persist across scene changes

### NativeAPI.cs

Platform-conditional messaging that routes to the correct native mechanism:

```csharp
using UnityEngine;
using System.Runtime.InteropServices;

namespace UnityKit
{
    public static class NativeAPI
    {
#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")]
        private static extern void SendMessageToFlutter(string message);

        [DllImport("__Internal")]
        private static extern void SendSceneLoadedToFlutter(
            string sceneName, int buildIndex, bool isLoaded, bool isValid);

        public static void SendToFlutter(string message)
        {
            SendMessageToFlutter(message);
        }

        public static void NotifySceneLoaded(
            string name, int buildIndex, bool isLoaded, bool isValid)
        {
            SendSceneLoadedToFlutter(name, buildIndex, isLoaded, isValid);
        }

#elif UNITY_ANDROID && !UNITY_EDITOR
        private static AndroidJavaClass _bridgeRegistry;

        private static AndroidJavaClass BridgeRegistry
        {
            get
            {
                if (_bridgeRegistry == null)
                    _bridgeRegistry = new AndroidJavaClass(
                        "com.unity_kit.FlutterBridgeRegistry");
                return _bridgeRegistry;
            }
        }

        public static void SendToFlutter(string message)
        {
            BridgeRegistry.CallStatic("sendMessageToFlutter", message);
        }

        public static void NotifySceneLoaded(
            string name, int buildIndex, bool isLoaded, bool isValid)
        {
            BridgeRegistry.CallStatic("sendSceneLoadedToFlutter",
                name, buildIndex, isLoaded, isValid);
        }

#else
        // Editor fallback: log to console
        public static void SendToFlutter(string message)
        {
            Debug.Log($"[UnityKit] SendToFlutter: {message}");
        }

        public static void NotifySceneLoaded(
            string name, int buildIndex, bool isLoaded, bool isValid)
        {
            Debug.Log($"[UnityKit] SceneLoaded: {name} (index={buildIndex})");
        }
#endif
    }
}
```

**Platform routing summary:**

| Platform | Mechanism | Target |
|----------|-----------|--------|
| iOS | `[DllImport("__Internal")]` | `extern "C"` in `UnityKitNativeBridge.mm` (compiled into UnityFramework, forwards via ObjC runtime to `FlutterBridgeRegistry`) |
| Android | `AndroidJavaClass` | `com.unity_kit.FlutterBridgeRegistry` static methods |
| Editor | `Debug.Log` | Console output for testing |

### ParameterHandler.cs

Auto-creates after scene load, subscribes to `FlutterBridge.OnTypedMessage`, and handles `SetParameter`/`ResetParameters` commands:

```csharp
using UnityEngine;

namespace UnityKit
{
    public class ParameterHandler : MonoBehaviour
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void AutoCreate()
        {
            if (FlutterBridge.Instance != null)
            {
                var handler = FlutterBridge.Instance.gameObject
                    .GetComponent<ParameterHandler>();
                if (handler == null)
                {
                    FlutterBridge.Instance.gameObject
                        .AddComponent<ParameterHandler>();
                }
            }
        }

        void OnEnable()
        {
            if (FlutterBridge.Instance != null)
            {
                FlutterBridge.Instance.OnFlutterMessage += HandleMessage;
            }
        }

        void OnDisable()
        {
            if (FlutterBridge.Instance != null)
            {
                FlutterBridge.Instance.OnFlutterMessage -= HandleMessage;
            }
        }

        private void HandleMessage(string target, string method, string data)
        {
            switch (method)
            {
                case "SetParameter":
                    // Parse and apply parameter
                    break;
                case "ResetParameters":
                    // Reset all parameters to defaults
                    break;
            }
        }
    }
}
```

---

## ProGuard / R8 Rules

The Android plugin uses reflection and JNI calls from Unity C#. Without ProGuard rules, release builds will silently fail because R8 strips or renames these classes.

### Required consumer rules

Create `android/consumer-rules.pro` in the plugin:

```
# unity_kit Flutter bridge (called from Unity C# via AndroidJavaClass)
-keep class com.unity_kit.FlutterBridgeRegistry { public static *; }

# Unity player classes (accessed via reflection)
-keep class com.unity3d.player.UnityPlayer { *; }
-keep class com.unity3d.player.UnityPlayerForActivityOrService { *; }
-keep class com.unity3d.player.IUnityPlayerLifecycleEvents { *; }
```

### Gradle configuration

```kotlin
// build.gradle.kts
android {
    defaultConfig {
        consumerProguardFiles("consumer-rules.pro")
    }
}
```

### What happens without ProGuard rules

1. R8 renames `FlutterBridgeRegistry` -- Unity C# `AndroidJavaClass("com.unity_kit.FlutterBridgeRegistry")` fails silently
2. R8 strips `sendMessageToFlutter` static method -- Unity messages never reach Flutter
3. R8 strips `UnityPlayerForActivityOrService` -- reflection-based player creation fails
4. All failures are **silent** in release builds (no crash, just non-functional)

---

## Complete Integration Flow

The full initialization sequence on Android:

```
1. Flutter creates AndroidView with viewType "com.unity_kit/unity_view"
2. UnityKitViewFactory.create() creates UnityKitViewController
3. Handler.postDelayed(100ms) defers initialization
4. UnityPlayerManager.createPlayer():
   a. Try Class.forName("...UnityPlayerForActivityOrService")
   b. Fall back to Class.forName("...UnityPlayer")
   c. Try constructor(Context, IUnityPlayerLifecycleEvents)
   d. Fall back to constructor(Context)
   e. Fall back to constructor(Activity)
5. getEmbeddableView():
   a. Try player.getFrameLayout() (Unity 6)
   b. Try player.getView()
   c. Fall back to player as View (legacy)
6. attachToContainer():
   a. Detach unityView from parent
   b. Add to container FrameLayout with MATCH_PARENT
7. activateRendering():
   a. unityView.requestFocus()
   b. player.windowFocusChanged(true)
   c. player.pause()
   d. player.resume()
8. Send "onUnityCreated" event to Flutter via MethodChannel
9. FlutterBridge.Start() sends {"type":"ready"} via NativeAPI
10. Dart bridge transitions to ready state, flushes queued messages
```

---

## Known Issues and Workarounds

### Black screen after initialization

**Cause:** Missing refocus pattern (step 7 above).

**Fix:** Ensure `windowFocusChanged(true)` + `pause()` + `resume()` are called after attaching the view.

### Touch not working

**Cause:** Missing `InputDevice.SOURCE_TOUCHSCREEN` on touch events, or `deviceId = 0` from Virtual Display.

**Fix:** Override `dispatchTouchEvent` to fix `deviceId` and set `source`.

### Unity view covers all Flutter widgets

**Cause:** Using `AndroidView` (Virtual Display). Unity's `SurfaceView` bypasses the offscreen texture and renders directly on screen.

**Fix:** Use `PlatformViewLink` + `initExpensiveAndroidView` (Hybrid Composition) with a delayed re-focus after attachment. Fixed in v0.9.2.

### Frozen rendering after orientation change

**Cause:** Unity rendering pipeline freezes when the Activity configuration changes.

**Fix:** Override `onWindowVisibilityChanged(VISIBLE)` on the container to call `pause()` + `resume()`.

### Release build silently broken

**Cause:** Missing ProGuard/R8 consumer rules.

**Fix:** Add `consumer-rules.pro` with keep rules for `com.unity_kit.**` and `com.unity3d.player.**`.

### Unity player created twice

**Cause:** Multiple platform views competing for the singleton Unity player.

**Fix:** Use `isAttached` flag and singleton `UnityPlayerManager` to ensure only one attachment at a time.

### Hot reload causes crash

**Cause:** `UnityPlayerManager` singleton holds stale Activity reference after hot restart.

**Fix:** Clean up in `onDetachedFromEngine` or use `WeakReference<Activity>` for the activity reference.

# Unity Kit -- Overview

A summary of what `unity_kit` is, how it works, and what to know before diving in.

---

## What Is This?

`unity_kit` is a Flutter plugin that lets you embed Unity 3D content inside a Flutter app. Flutter handles the UI, Unity handles 3D rendering -- they communicate by sending JSON messages through a native bridge.

**Supported platforms:** Android, iOS
**Supported Unity versions:** 2022.3 LTS, Unity 6 (6000+)

---

## Architecture in 30 Seconds

```
┌─────────────────────────────────────────────────┐
│                   Flutter App                    │
│                                                  │
│   UnityView widget ──── UnityBridge (singleton)  │
│        │                      │                  │
│        │                MethodChannel            │
│        │                      │                  │
├────────┼──────────────────────┼──────────────────┤
│   Platform View          Native Plugin           │
│   (Android/iOS)     (Kotlin/Swift singleton)     │
│                           │                      │
├───────────────────────────┼──────────────────────┤
│                    Unity Player                   │
│           (UnityFramework / UnityPlayer)          │
│                                                  │
│   FlutterBridge.cs ── MessageRouter ── Handlers  │
└─────────────────────────────────────────────────┘
```

**Key point:** The bridge (communication layer) is independent of the widget. You create it once, pass it to widgets, and it survives navigation. This is the biggest difference from `flutter_unity_widget` where the controller dies with the widget.

---

## What's in the Box

### Dart (Flutter side)

| Component | What it does |
|-----------|-------------|
| `UnityBridge` | Abstract interface for communication. Create once, use everywhere. |
| `UnityView` | Widget that displays the Unity view. Thin wrapper -- delegates to bridge. |
| `UnityMessage` | Typed message model with factory constructors (`command`, `to`, `fromJson`). |
| `LifecycleManager` | State machine: `uninitialized` -> `ready` -> `paused` -> `disposed`. |
| `ReadinessGuard` | Queues messages until Unity is ready. Auto-flushes on engine start. |
| `MessageBatcher` | Groups rapid messages into single native calls. |
| `MessageThrottler` | Rate-limits outgoing messages. |
| `StreamingController` | Downloads bundles from CDN, verifies SHA-256, manages cache. |

### C# (Unity side)

| Script | What it does |
|--------|-------------|
| `FlutterBridge.cs` | Singleton. Receives all messages from Flutter, routes to handlers. |
| `FlutterMonoBehaviour.cs` | Base class for scripts that receive Flutter messages. Auto-registers. |
| `MessageRouter.cs` | Static registry: target name -> handler callback. |
| `NativeAPI.cs` | Platform-conditional: iOS uses `[DllImport]`, Android uses `AndroidJavaClass`. |
| `MessageBatcher.cs` | Collects messages per frame, flushes as JSON array in `LateUpdate`. |
| `SceneTracker.cs` | Auto-notifies Flutter when scenes load/unload. |
| `FlutterAddressablesManager.cs` | Handles asset loading via Addressables (optional). |

### Native (platform bridge)

| Platform | What it does |
|----------|-------------|
| **Android (Kotlin)** | `UnityPlayerManager` singleton creates/manages Unity player via reflection. Supports both `UnityPlayer` (legacy) and `UnityPlayerForActivityOrService` (Unity 6). |
| **iOS (Swift)** | `UnityPlayerManager` singleton loads `UnityFramework.framework` from app bundle. |
| **iOS (.mm bridge)** | `UnityKitNativeBridge.mm` provides `extern "C"` symbols for IL2CPP `[DllImport]`. Compiled into UnityFramework, forwards to Flutter plugin via ObjC runtime. |

---

## Communication Flow

### Flutter -> Unity

```
Dart bridge.send(UnityMessage)
  -> MethodChannel
    -> Native UnityPlayerManager.sendMessage()
      -> Unity UnitySendMessage("FlutterBridge", "ReceiveMessage", json)
        -> FlutterBridge.cs parses JSON
          -> MessageRouter dispatches to registered handler
```

### Unity -> Flutter

```
Unity NativeAPI.SendToFlutter(json)
  -> [iOS] DllImport -> .mm bridge -> ObjC runtime -> FlutterBridgeRegistry
  -> [Android] AndroidJavaClass -> FlutterBridgeRegistry
    -> MethodChannel event to Dart
      -> bridge.messageStream emits UnityMessage
```

---

## Key Design Decisions

### 1. Bridge is not tied to the widget

The bridge is a service. You create it once (e.g., in a provider or service locator), pass it to `UnityView`, and it survives widget rebuilds and navigation. This prevents the #1 reported issue from `flutter_unity_widget` (controller dying on navigation).

### 2. Readiness guard prevents message loss

With `flutter_unity_widget`, messages sent before Unity is ready are silently dropped. `unity_kit` queues them and auto-flushes when ready:

```dart
bridge.sendWhenReady(message); // safe -- queues if not ready
bridge.send(message);          // throws EngineNotReadyException if not ready
```

### 3. Unity is a singleton per process

Unity can only have one player instance per app process. `UnityPlayerManager` is a singleton. You can't create multiple Unity views or restart Unity after `quit()`. This is a Unity platform limitation, not a `unity_kit` choice.

### 4. Reflection for Unity version compatibility

Instead of compile-time dependency on Unity classes, the Android native layer uses reflection. This means the same plugin binary works with Unity 2022.3 and Unity 6 without recompilation.

### 5. Typed exceptions instead of silent failures

Every error has a specific exception type: `BridgeException`, `EngineNotReadyException`, `LifecycleException`, `CommunicationException`. No more `catch(e) { /* todo */ }`.

---

## Export Workflow Summary

```
Unity Editor                         Flutter Project
     │                                      │
     │ Flutter > Export Android/iOS          │
     │──────────────────────────────>  Builds/ folder
     │                                      │
     │ Flutter > Deploy to Flutter Project   │
     │──────────────────────────────>  android/unityLibrary/
     │                                 ios/UnityLibrary/
     │                                      │
     │                                 flutter run
```

Build.cs handles all the post-processing automatically:
- Converts Unity app -> library module
- Patches Gradle files (both Groovy and Kotlin DSL)
- Adds ProGuard rules
- Strips unnecessary manifest entries
- Handles Unity 6 folder structure differences

---

## Asset Streaming Summary

For downloading 3D content from a CDN at runtime:

```
CDN                     Flutter                    Unity
 │                        │                          │
 │ content_manifest.json  │                          │
 │ ───────────────────> parse bundles list           │
 │                        │                          │
 │ bundle.bundle          │                          │
 │ ───────────────────> download + SHA-256 verify    │
 │                        │                          │
 │                        │ SetCachePath ──────────> │
 │                        │ LoadToyRemote ─────────> │
 │                        │                          │ Addressables.LoadAssetAsync()
 │                        │                          │ (reads from local cache)
 │                        │ <────── toy_loaded ───── │
```

The manifest tells Flutter what to download. The addressable key maps a bundle to what Unity needs to load it. Everything else is automatic.

---

## What This Doesn't Do

- **No desktop support** -- Unity-as-a-library doesn't support desktop embedding
- **No web support** (production-ready) -- technically possible via iframe + postMessage, but not battle-tested
- **No multiple Unity instances** -- one player per process, period
- **No full memory release** -- Unity retains 80-180MB after unload. Swap scenes to free scene-specific resources, but the runtime itself stays in memory
- **No iOS Simulator** -- UnityFramework is built for `arm64` device only

# FAQ -- Common Problems and Solutions

Collected from real issues, debugging sessions, and integration patterns across `flutter_unity_widget` (2,300+ stars, 272+ open issues) and `unity_kit` development.

---

## Build Problems

### No "Flutter" menu in Unity Editor

`Assets/Scripts/UnityKit/Editor/Build.cs` is missing or has compilation errors. Check Unity Console for errors. Editor scripts must be inside an `Editor/` folder.

### Android: `ClassNotFoundException` for `com.unity_kit.*` in release builds

ProGuard/R8 is stripping classes used via reflection and JNI. `Build.cs` auto-adds ProGuard rules during export, but verify `proguard-unity.txt` exists in `unityLibrary/` and contains:

```
-keep class com.unity_kit.** { *; }
-keep class com.unity3d.player.** { *; }
```

This is **critical** -- without it, release builds silently fail (no crash, just non-functional).

### Android: Gradle/Kotlin/JVM version mismatch

Every new Flutter version can change the Gradle/Kotlin/JVM requirements. `Build.cs` patches `build.gradle` automatically during export. If you see version mismatches:

1. Re-export from Unity (**Flutter > Export Android**)
2. Make sure `Build.cs` is up-to-date (latest from `unity_kit/unity/`)
3. Flutter 3.29+ uses Kotlin DSL (`build.gradle.kts`) -- `Build.cs` handles both

### iOS: "No such module 'UnityFramework'"

`UnityFramework.framework` is not in the expected location. Check:

1. The iOS export completed successfully (**Flutter > Export iOS**)
2. `Builds/ios/UnityLibrary/` contains the Xcode project
3. For local dev: create a symlink from `unity_kit/ios/` to the built framework

### iOS: "Undefined symbol: _SendMessageToFlutter"

The `UnityKitNativeBridge.mm` file is not compiled into `UnityFramework`. It must be in `Assets/Plugins/iOS/` **before** the Unity export. Unity's build system automatically includes files from that folder.

### IL2CPP stripping removes my serializable classes

Add your custom `[Serializable]` classes to `link.xml`:

```xml
<linker>
    <assembly fullname="Assembly-CSharp">
        <type fullname="YourNamespace.YourClass" preserve="all"/>
    </assembly>
</linker>
```

`unity_kit`'s own `link.xml` already preserves UnityKit DTOs.

### NamedBuildTarget / Il2CppCodeGeneration compilation errors

These APIs exist only in Unity 6000+. `Build.cs` uses `BuildTargetGroup` instead (compatible with Unity 2022.3+). Make sure you have the latest `Build.cs` from `unity_kit/unity/Assets/Scripts/UnityKit/Editor/`.

---

## Rendering Problems

### Black screen after Unity loads (Android)

Unity needs an explicit "refocus" after being embedded in a Flutter platform view:

```
windowFocusChanged(true) -> pause() -> resume()
```

`unity_kit` handles this automatically in `UnityKitViewController`. If you still see a black screen:

1. Make sure you're using the latest `unity_kit` version
2. Check that `UnityPlayerManager` successfully created the player (check logs)
3. Verify the platform view mode is `AndroidView` (Virtual Display), not `PlatformViewLink` (Hybrid Composition -- causes app freeze)

### White/blank screen (iOS)

**Most common cause:** Unity's Metal renderer creates textures matching the view size. If initialized before the view has layout, it gets 0x0 and crashes (`MTLTextureDescriptor has width of zero`).

`unity_kit` prevents this with `waitForNonZeroFrame()` -- polls until the container view has non-zero bounds. If the problem persists:

1. Make sure `UnityView` has a non-zero size in the layout (not hidden, not zero-height)
2. Check that `UnityFramework.framework` loaded successfully (iOS logs)
3. Check for `onError` events on the Dart side

**After scene change:** Unity's window level might reset. `unity_kit` sets Unity's window level below Flutter's (`UIWindow.Level.normal - 1`).

### Unity renders on top of Flutter widgets (Android)

This is a known platform issue, especially on Android < 10. SurfaceView z-ordering is unreliable. Workarounds:

1. Use Android 10+ if possible
2. Use `AndroidView` (Virtual Display) mode -- this renders Unity into a virtual display that Flutter composites

### Frozen rendering after orientation change (Android)

The `UnityContainerLayout` overrides `onWindowVisibilityChanged(VISIBLE)` to call `pause()` + `resume()`, which restarts the rendering pipeline. If you're using a custom container, add this pattern.

---

## Communication Problems

### Messages not reaching Unity from Flutter

1. `FlutterBridge` GameObject must exist in the first loaded scene (auto-creates via `[RuntimeInitializeOnLoadMethod]`, but manual placement is recommended)
2. `sendReadyOnStart` must be enabled on the `FlutterBridge` component
3. Check the target name matches -- `FlutterMonoBehaviour` uses `GameObject.name` by default (or the custom `Target Name` field)
4. Check Unity Console for: `[UnityKit] No handler registered for target: xxx`

### Messages not reaching Flutter from Unity

1. Use `NativeAPI.SendToFlutter()` (not `Debug.Log`)
2. **Android:** verify `com.unity_kit.FlutterBridgeRegistry` is not stripped by ProGuard (see Build Problems above)
3. **iOS:** verify `UnityKitNativeBridge.mm` is in `Assets/Plugins/iOS/` and compiled into UnityFramework
4. **Editor:** messages go to Console only -- no Flutter connection in Play Mode

### Messages sent before Unity is ready are lost

Use `bridge.sendWhenReady()` instead of `bridge.send()`. The readiness guard queues messages and auto-flushes when Unity reports ready.

```dart
// This throws EngineNotReadyException if Unity isn't ready:
bridge.send(message);

// This queues and sends automatically when ready:
bridge.sendWhenReady(message);
```

### Communication breaks after re-navigation

`unity_kit` uses a bridge independent of the widget. Unlike `flutter_unity_widget` where the controller dies with the widget, `unity_kit`'s bridge survives navigation.

```dart
// Create bridge once (e.g., in a service/provider)
final bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);

// Pass to widget -- widget does NOT dispose it
UnityView(bridge: bridge, ...);
```

If you let the widget create its own bridge (`bridge: null`), it will be disposed when the widget is removed.

---

## Lifecycle Problems

### Unity can't be restarted after `quit()`

This is a Unity limitation, not a `unity_kit` bug. Unity's player cannot be restarted after `quit()` -- it kills the process. Use `pause()` / `resume()` instead. If you need to "reset", load an empty scene.

### Memory keeps growing after navigation

Unity retains 80-180MB even after "unload". This is a platform limitation. Best practices:

1. Keep Unity alive, swap scenes (don't try to destroy/recreate)
2. Load an empty scene before disposing the widget to free scene-specific resources
3. Use `Addressables.Release()` to unload assets you no longer need

### App crashes after 2-3 navigations (flutter_unity_widget)

This is a known issue in `flutter_unity_widget` (#281, open for 5+ years). Resources are never freed. `unity_kit` addresses this with proper `dispose()` chains and `WeakListener` patterns, but the fundamental Unity memory behavior remains.

---

## Touch Problems

### Touch doesn't work (Android)

Two common causes:

1. **Missing source type:** Unity's New Input System requires `InputDevice.SOURCE_TOUCHSCREEN`. `unity_kit`'s `UnityContainerLayout` sets this automatically.
2. **DeviceId = 0:** Flutter's Virtual Display sends events with `deviceId = 0`, which Unity ignores. `unity_kit` patches this.

If using a custom touch handler, make sure both fixes are applied.

### Multi-touch doesn't work (iOS)

Check that gesture recognizers on the Unity view are configured. `unity_kit` forwards touch events via UIKit. If your Unity project uses the old Input Manager, multi-touch should work. With the New Input System, verify the `EnhancedTouch` module is enabled.

---

## Asset Streaming Problems

### Addressable asset not found / toy_error

1. **SetCachePath must be called first** -- Flutter must tell Unity where the downloaded bundles are before any load
2. Verify the **addressable key** matches between Flutter and Unity (what Flutter sends must match the "Address" field in Unity's Addressables Groups window)
3. Check that the bundle was actually downloaded to the cache path (verify file exists)
4. Rebuild Addressables after any asset changes: `Flutter > Build Addressables`

### content_manifest.json missing addressableKeys

`AddressablesManifestBuilder` generates `metadata.addressableKeys` by matching Addressable group entries to built bundle filenames. If keys are missing:

1. Rebuild: `Flutter > Build Addressables`
2. Check that the asset has an address set in the Addressables Groups window
3. Check that the asset's group has Remote build/load paths

### Bundles download but Unity can't load them

The `TransformInternalId` callback in `FlutterAddressablesManager` intercepts Unity's remote URLs and redirects to the local cache. Check:

1. `SetCachePath` was called with the correct path
2. The bundle filename in cache matches what Unity expects
3. The catalog was loaded (`LoadContentCatalog` or `UpdateCatalog`)

---

## Unity 6 Specific

### Unity 6 constructor differences

Unity 6 renamed the player class:

| Unity Version | Class | Constructor |
|---------------|-------|-------------|
| 2022.3 | `UnityPlayer` | `UnityPlayer(Activity)` |
| 6000+ | `UnityPlayerForActivityOrService` | `(Context, IUnityPlayerLifecycleEvents?)` |

`unity_kit` tries both automatically via reflection. No manual configuration needed.

### Unity 6 view extraction

Unity 6's player is not a `View`. You must call `getFrameLayout()` to get the embeddable view. `unity_kit` tries multiple methods: `getFrameLayout()`, `getView()`, `getPlayerView()`, `getSurfaceView()`, `getRootView()`, and finally falls back to treating the player as a `View` (legacy).

---

## Platform-Specific Notes

### iOS Simulator not supported

`UnityFramework.framework` is built for `arm64` device architecture only. Always test on physical devices. On Apple Silicon Macs, the simulator runs `arm64` but may still have compatibility issues.

### NSLog not visible in `flutter run` output

`flutter run` only captures `Debug.Log` (Unity) and `print()` (Dart). Swift `NSLog` is not forwarded. For debugging, send info through the bridge:

```swift
sendEvent(name: "onUnityMessage", data: "debug:someValue=\(value)")
```

### Android: Hybrid Composition causes app freeze

Do NOT use `PlatformViewLink` + `initExpensiveAndroidView` for the Unity view. Use `AndroidView` (Virtual Display mode). Hybrid Composition conflicts with Unity's rendering pipeline.

---

## General Tips

1. **Always re-export after Unity changes** -- any change to scripts, assets, or settings requires a new export
2. **FlutterBridge is DontDestroyOnLoad** -- it persists across scene changes, no need to add it to every scene
3. **Bridge != Widget** -- create the bridge in a service layer, pass it to widgets. Don't let each widget create its own bridge.
4. **Check logs** -- Unity logs with `[UnityKit]` prefix. Dart exceptions include the lifecycle state and context.
5. **Test on device, not simulator** -- especially iOS. The simulator doesn't support UnityFramework.

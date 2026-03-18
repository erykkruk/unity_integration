# Unity Export Guide

Step-by-step guide for preparing a Unity project and exporting it as a library module for use with `unity_kit` in Flutter.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture: Separate Projects](#architecture-separate-projects)
- [Step 1: Install UnityKit Scripts](#step-1-install-unitykit-scripts)
- [Step 2: Prepare the Scene](#step-2-prepare-the-scene)
- [Step 3: Write Game Scripts](#step-3-write-game-scripts)
- [Step 4: Configure Build Settings](#step-4-configure-build-settings)
- [Step 5: Export](#step-5-export)
  - [Android](#android)
  - [iOS](#ios)
  - [WebGL](#webgl)
- [Step 6: Deploy to Flutter](#step-6-deploy-to-flutter)
  - [Option A: Manual deploy from Settings](#option-a-manual-deploy-from-settings)
  - [Option B: Auto-deploy on export](#option-b-auto-deploy-on-export)
  - [Option C: CI pipeline](#option-c-ci-pipeline)
- [Step 7: Flutter Integration](#step-7-flutter-integration)
- [What Build.cs Does Automatically](#what-buildcs-does-automatically)
- [C# Script Reference](#c-script-reference)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Unity Editor | 2022.3 LTS or newer |
| Flutter | 3.0+ |
| unity_kit | Added as dependency in `pubspec.yaml` |
| Android SDK | API 24+ (for Android export) |
| Xcode | 14+ (for iOS export) |

---

## Architecture: Separate Projects

The Unity project and Flutter project are **completely separate** -- they can live in different folders, different repos, or even different machines. Build.cs exports Unity as a standalone artifact to a local `Builds/` folder. You then optionally deploy that artifact to a Flutter project.

```
+------------------------------+      +------------------------------+
|  Unity Project (any folder)  |      |  Flutter Project (any folder)|
|                              |      |                              |
|  MyUnityProject/             |      |  my_flutter_app/             |
|  +-- Assets/                 |      |  +-- android/                |
|  |   +-- Scripts/UnityKit/   |      |  |   +-- unityLibrary/ <-+   |
|  |   +-- Scenes/             |      |  +-- ios/                |   |
|  +-- Builds/  <-- artifacts  |------|  |   +-- UnityLibrary/ <-+   |
|  |   +-- android/            | copy |  +-- web/                |   |
|  |   |   +-- unityLibrary/  -|------|  |   +-- UnityLibrary/ <-+   |
|  |   +-- ios/                |      |  +-- lib/                    |
|  |   |   +-- UnityLibrary/   |      |  +-- pubspec.yaml            |
|  |   +-- web/                |      +------------------------------+
|  |       +-- UnityLibrary/   |
|  +-- ProjectSettings/        |
+------------------------------+
```

**Two export modes:**

| Mode | When | How |
|------|------|-----|
| **Standalone** (default) | CI builds, different repos, team workflows | Export to `Builds/` folder. Upload as artifact. |
| **Deploy** (optional) | Local development, same machine | Set Flutter project path in Settings. Artifacts auto-copied on export. |

---

## Step 1: Install UnityKit Scripts

Copy the entire `UnityKit/` folder from the unity_kit package into your Unity project:

```
Source:  unity_kit/unity/Assets/Scripts/UnityKit/
Target:  YourUnityProject/Assets/Scripts/UnityKit/
```

After copying, your project should have:

```
Assets/Scripts/UnityKit/
+-- Editor/
|   +-- Build.cs                      # Export automation (Flutter menu)
|   +-- XCodePostBuild.cs             # iOS Xcode post-processing
|   +-- SweetShellHelper.cs           # Shell helper for build scripts
+-- FlutterBridge.cs                  # Singleton message receiver
+-- FlutterMessage.cs                 # Message DTO: {target, method, data}
+-- FlutterMonoBehaviour.cs           # Base class for Flutter-aware scripts
+-- MessageBatcher.cs                 # Per-frame message batching
+-- MessageRouter.cs                  # Target-based message routing
+-- NativeAPI.cs                      # Platform-specific native calls
+-- SceneTracker.cs                   # Auto scene load/unload notifications
+-- FlutterAddressablesManager.cs     # Addressables integration (optional)
+-- link.xml                          # IL2CPP type preservation
```

Open the Unity project in Unity Editor. Wait for scripts to compile. You should see a **Flutter** menu appear in the menu bar.

---

## Step 2: Prepare the Scene

### 2.1 Create the FlutterBridge GameObject

The `FlutterBridge` is the main entry point for Flutter-Unity communication. It must exist in your first loaded scene.

1. Open your main scene in Unity Editor
2. Create an empty GameObject: **GameObject > Create Empty**
3. Rename it to `FlutterBridge`
4. Add the `FlutterBridge` component: **Add Component > UnityKit > FlutterBridge**

**FlutterBridge settings:**

| Property | Default | Description |
|----------|---------|-------------|
| Send Ready On Start | `true` | Sends `{"type":"ready"}` to Flutter when Unity starts. Keep enabled. |

### 2.2 Add SceneTracker (optional)

If you want Flutter to receive automatic scene load/unload notifications:

1. Select the `FlutterBridge` GameObject
2. **Add Component > UnityKit > SceneTracker**

This automatically notifies Flutter via `NativeAPI.NotifySceneLoaded()` whenever a scene loads or unloads.

### 2.3 Add MessageBatcher (optional)

If your game sends many messages per frame to Flutter:

1. Select the `FlutterBridge` GameObject
2. **Add Component > UnityKit > MessageBatcher**

This batches all messages sent via `SendToFlutterBatched()` and flushes them as a single JSON array in `LateUpdate`.

### 2.4 Final FlutterBridge GameObject

```
FlutterBridge (GameObject)
+-- FlutterBridge       (required)
+-- SceneTracker        (optional - auto scene notifications)
+-- MessageBatcher      (optional - per-frame batching)
```

The FlutterBridge uses `DontDestroyOnLoad`, so it persists across scene changes.

### 2.5 Add Scenes to Build Settings

1. Open **File > Build Settings**
2. Click **Add Open Scenes** for every scene you want included
3. Make sure your main scene is at index 0

---

## Step 3: Write Game Scripts

### Option A: Extend FlutterMonoBehaviour (recommended)

The simplest way to receive messages from Flutter. Auto-registers with `MessageRouter`.

```csharp
using UnityEngine;
using UnityKit;

public class ModelController : FlutterMonoBehaviour
{
    [SerializeField] private GameObject myModel;

    // Called when Flutter sends a message targeting this object.
    // Target name = GameObject name (or override via Inspector).
    protected override void OnFlutterMessage(string method, string data)
    {
        switch (method)
        {
            case "Rotate":
                float angle = float.Parse(data);
                myModel.transform.Rotate(0, angle, 0);
                break;

            case "SetColor":
                // data could be JSON: {"r":1,"g":0,"b":0}
                var color = JsonUtility.FromJson<ColorData>(data);
                GetComponent<Renderer>().material.color =
                    new Color(color.r, color.g, color.b);
                break;

            case "GetState":
                // Send response back to Flutter
                SendToFlutter("model_state", myModel.transform.eulerAngles.y.ToString());
                break;
        }
    }
}

[System.Serializable]
public class ColorData
{
    public float r, g, b;
}
```

**From Flutter:**

```dart
// Target = GameObject name that has ModelController component
await bridge.send(UnityMessage.to('ModelObject', 'Rotate', {'angle': '45'}));
await bridge.send(UnityMessage.to('ModelObject', 'SetColor', {'r': 1, 'g': 0, 'b': 0}));
```

**Custom target name:**

In the Inspector, set the `Target Name` field on your `FlutterMonoBehaviour` to override the default (which uses the GameObject name).

### Option B: Register with MessageRouter manually

For scripts that don't inherit from `FlutterMonoBehaviour`:

```csharp
using UnityEngine;
using UnityKit;

public class GameManager : MonoBehaviour
{
    void OnEnable()
    {
        MessageRouter.Register("GameManager", HandleMessage);
    }

    void OnDisable()
    {
        MessageRouter.Unregister("GameManager");
    }

    private void HandleMessage(string method, string data)
    {
        if (method == "StartGame")
        {
            // Start game logic
            NativeAPI.SendToFlutter("{\"type\":\"game_started\"}");
        }
    }
}
```

### Option C: Listen to FlutterBridge events directly

For global message handling:

```csharp
using UnityEngine;
using UnityKit;

public class DebugLogger : MonoBehaviour
{
    void OnEnable()
    {
        if (FlutterBridge.Instance != null)
        {
            FlutterBridge.Instance.OnFlutterMessage += OnMessage;
            FlutterBridge.Instance.OnReady += OnReady;
        }
    }

    void OnDisable()
    {
        if (FlutterBridge.Instance != null)
        {
            FlutterBridge.Instance.OnFlutterMessage -= OnMessage;
            FlutterBridge.Instance.OnReady -= OnReady;
        }
    }

    private void OnMessage(string target, string method, string data)
    {
        Debug.Log($"Flutter -> Unity: {target}.{method}({data})");
    }

    private void OnReady()
    {
        Debug.Log("FlutterBridge is ready");
    }
}
```

### Sending messages to Flutter

```csharp
// Direct send (immediate)
NativeAPI.SendToFlutter("{\"type\":\"score\",\"data\":\"100\"}");

// Via FlutterMonoBehaviour helper (immediate)
SendToFlutter("score", "100");

// Via batcher (batched per frame, sent in LateUpdate)
SendToFlutterBatched("position", $"{transform.position.x},{transform.position.y}");
```

### Message format

All messages between Flutter and Unity use this JSON structure:

```
Flutter -> Unity:  {"target":"ModelObject", "method":"Rotate", "data":"45"}
Unity -> Flutter:  {"type":"score", "data":"100"}
```

| Direction | Format | Entry point |
|-----------|--------|-------------|
| Flutter -> Unity | `FlutterMessage` (`target`, `method`, `data`) | `FlutterBridge.ReceiveMessage(json)` |
| Unity -> Flutter | Free-form JSON with `type` field | `NativeAPI.SendToFlutter(json)` |
| Unity -> Flutter (scene) | Native call with structured args | `NativeAPI.NotifySceneLoaded(name, buildIndex, isLoaded, isValid)` |

---

## Step 4: Configure Build Settings

### 4.1 Player Settings

Open **Edit > Project Settings > Player**:

**Android:**

| Setting | Value | Why |
|---------|-------|-----|
| Scripting Backend | IL2CPP | Required for release builds |
| Target Architectures | ARM64 (+ ARMv7 optional) | Flutter requires ARM64 |
| Minimum API Level | 24 | Flutter minimum |

> **IMPORTANT: ARM64 is required.** Most modern Android devices are 64-bit (arm64-v8a). If you only export ARMv7, the Unity player will fail to initialize on arm64 devices — the app launches but the Unity view never loads (you will see `Unity view not available after N attempts` in logcat). Always enable ARM64 in Target Architectures. ARMv7 can be added alongside it for older 32-bit device support, but ARM64 alone is sufficient for most use cases.

**iOS:**

| Setting | Value | Why |
|---------|-------|-----|
| Scripting Backend | IL2CPP | Required |
| Target SDK | Device SDK | Simulator not supported |
| Architecture | ARM64 | Required |

### 4.2 Scenes in Build

Open **File > Build Settings**. Verify all required scenes are listed and checked.

### 4.3 Addressables (optional)

If using Unity Addressables:

1. Add the `ADDRESSABLES_INSTALLED` scripting define symbol in **Player Settings > Other Settings > Scripting Define Symbols**
2. The `FlutterAddressablesManager` component becomes available
3. Add it to the `FlutterBridge` GameObject

---

## Step 5: Export

Exports always go to the `Builds/` folder inside your Unity project. If a Flutter project path is configured (see [Step 6](#step-6-deploy-to-flutter)), artifacts are also auto-copied there.

### Android

1. Open the Unity project in Unity Editor
2. Switch platform to Android: **File > Build Settings > Android > Switch Platform**
3. Export:
   - **Flutter > Export Android (Debug)** (shortcut: `Ctrl+Alt+N`)
   - **Flutter > Export Android (Release)** (shortcut: `Ctrl+Alt+M`)

Output: `<unity-project>/Builds/android/unityLibrary/`

### iOS

1. Open the Unity project in Unity Editor
2. Switch platform to iOS: **File > Build Settings > iOS > Switch Platform**
3. Wait for reimport to complete
4. Export:
   - **Flutter > Export iOS (Debug)** (shortcut: `Ctrl+Alt+I`)
   - **Flutter > Export iOS (Release)**

Output: `<unity-project>/Builds/ios/UnityLibrary/`

### WebGL

1. Switch platform to WebGL: **File > Build Settings > WebGL > Switch Platform**
2. Export: **Flutter > Export WebGL** (shortcut: `Ctrl+Alt+W`)

Output: `<unity-project>/Builds/web/UnityLibrary/`

---

## Step 6: Deploy to Flutter

After exporting, you need to get the artifacts into your Flutter project. Three options:

### Option A: Manual deploy from Settings

1. Open **Flutter > Settings** (shortcut: `Ctrl+Alt+S`)
2. Set the Flutter project path (Browse or paste)
3. Click **Save Flutter Project Path**
4. Click **Deploy to Flutter Project**

This copies whichever artifacts exist (`Builds/android/`, `Builds/ios/`, `Builds/web/`) into the Flutter project and patches Gradle files for Android.

### Option B: Auto-deploy on export

If you configure a Flutter project path in Settings (or via env var), every export automatically copies the artifact to the Flutter project after building. No manual deploy step needed.

1. Open **Flutter > Settings**
2. Set and save the Flutter project path
3. Run any export (e.g., **Flutter > Export Android (Debug)**)
4. Build completes -> artifact appears in `Builds/` -> auto-copied to Flutter project

### Option C: CI pipeline

For CI/CD, use environment variables and batch mode:

```bash
# Set the Flutter project path (optional -- skip for standalone artifact)
export UNITY_KIT_FLUTTER_PROJECT="/path/to/my_flutter_app"

# Android Debug
Unity -quit -batchmode -projectPath /path/to/MyUnityProject \
  -executeMethod UnityKit.Editor.Build.ExportAndroidDebug

# Android Release
Unity -quit -batchmode -projectPath /path/to/MyUnityProject \
  -executeMethod UnityKit.Editor.Build.ExportAndroidRelease

# iOS Debug (must set -buildTarget iOS)
Unity -quit -batchmode -projectPath /path/to/MyUnityProject \
  -buildTarget iOS \
  -executeMethod UnityKit.Editor.Build.ExportIOSDebug

# iOS Release
Unity -quit -batchmode -projectPath /path/to/MyUnityProject \
  -buildTarget iOS \
  -executeMethod UnityKit.Editor.Build.ExportIOSRelease

# WebGL
Unity -quit -batchmode -projectPath /path/to/MyUnityProject \
  -executeMethod UnityKit.Editor.Build.ExportWebGL
```

**CI standalone artifact (no Flutter project):**

Without `UNITY_KIT_FLUTTER_PROJECT`, artifacts remain in `Builds/`. Upload them as CI artifacts and download in the Flutter CI pipeline:

```yaml
# Example GitHub Actions workflow
unity-build:
  steps:
    - name: Export Android
      run: Unity -quit -batchmode ...
    - name: Upload artifact
      uses: actions/upload-artifact@v4
      with:
        name: unity-android
        path: MyUnityProject/Builds/android/unityLibrary/

flutter-build:
  needs: unity-build
  steps:
    - name: Download Unity artifact
      uses: actions/download-artifact@v4
      with:
        name: unity-android
        path: my_flutter_app/android/unityLibrary/
    - name: Build Flutter
      run: cd my_flutter_app && flutter build apk
```

---

## Step 7: Flutter Integration

After deploying artifacts to your Flutter project:

### 7.1 Add dependency

```yaml
# pubspec.yaml
dependencies:
  unity_kit:
    path: path/to/unity_kit
```

### 7.2 Minimal Flutter code

```dart
import 'package:flutter/material.dart';
import 'package:unity_kit/unity_kit.dart';

class GameScreen extends StatelessWidget {
  const GameScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: UnityView(
        config: const UnityConfig(sceneName: 'MainScene'),
        placeholder: const UnityPlaceholder(message: 'Loading Unity...'),
        onReady: (bridge) {
          bridge.send(UnityMessage.command('StartGame'));
        },
        onMessage: (msg) {
          debugPrint('Unity says: ${msg.type} = ${msg.data}');
        },
        onSceneLoaded: (scene) {
          debugPrint('Scene loaded: ${scene.name}');
        },
      ),
    );
  }
}
```

### 7.3 Run

```bash
cd my_flutter_app
flutter pub get
flutter run
```

---

## What Build.cs Does Automatically

### Export modes

| Mode | Trigger | Artifact location | Gradle patching |
|------|---------|-------------------|-----------------|
| **Standalone** | Every export | `<unity-project>/Builds/<platform>/` | Patches artifact only (library conversion) |
| **Auto-deploy** | Export with Flutter path configured | Also copies to `<flutter-project>/<platform>/` | Patches artifact + Flutter project gradle |
| **Manual deploy** | **Flutter > Deploy to Flutter Project** | Copies existing `Builds/` to Flutter project | Patches Flutter project gradle |

### Settings window (Flutter > Settings)

| Section | Description |
|---------|-------------|
| Build Artifacts | Shows paths and build status (BUILT / --) for each platform |
| Flutter Project | Optional path to Flutter project. Checks for `pubspec.yaml`. |
| Quick Export | Buttons for all export variants |
| Deploy to Flutter Project | Copy artifacts to configured Flutter project |
| Clean All Builds | Delete everything in `Builds/` |

### Flutter project path resolution

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | `UNITY_KIT_FLUTTER_PROJECT` env var | `export UNITY_KIT_FLUTTER_PROJECT=/path/to/app` |
| 2 | EditorPrefs (set via Settings GUI) | Browse button in Settings window |

### Android post-processing

| Step | What | Why |
|------|------|-----|
| 1 | `com.android.application` -> `com.android.library` | Unity exports as app, Flutter needs a library module |
| 2 | Remove `applicationId` | Libraries don't have their own app ID |
| 3 | Add `namespace 'com.unity3d.player'` | Required by Android Gradle Plugin 8+ |
| 4 | Comment out `ndkPath` | Conflicts with Flutter's NDK configuration |
| 5 | Fix `../shared/` -> `./shared/` | Unity 6 shared folder path correction |
| 6 | Replace `fileTree` -> `unity-classes` jar | Correct dependency for library mode |
| 7 | Strip `<activity>` from manifest | Flutter hosts the activity, not Unity |
| 8 | Add ProGuard keep rules | Preserve `com.unity_kit.**` and `com.unity3d.player.**` from stripping |
| 9 | Add `game_view_content_description` string | Accessibility content description |

Steps 10-12 below only run during **deploy** (not standalone export):

| Step | What | Why |
|------|------|-----|
| 10 | Add `include ':unityLibrary'` to settings.gradle | Register Unity module in Flutter project |
| 11 | Add `flatDir` repository | Resolve `unity-classes.jar` |
| 12 | Add `implementation project(':unityLibrary')` | Wire dependency in app/build.gradle |

### iOS post-processing (XCodePostBuild)

| Step | What | Why |
|------|------|-----|
| 1 | Inject `UnityReady` NSNotification in `startUnity:` | unity_kit iOS plugin observes this to know Unity is ready |
| 2 | Set `SKIP_INSTALL = YES` on UnityFramework target | Required for framework builds |
| 3 | Set `ENABLE_BITCODE = NO` on project | Bitcode is deprecated |
| 4 | Add `Data` folder reference to UnityFramework | Required for Unity data files to be included |

unity_kit uses an Objective-C++ native bridge (`UnityKitNativeBridge.mm`) placed in `Assets/Plugins/iOS/` for message bridging. This file provides `extern "C"` symbols (`SendMessageToFlutter`, `SendSceneLoadedToFlutter`) that IL2CPP's `[DllImport("__Internal")]` resolves at link time within `UnityFramework`. At runtime, these symbols forward to `FlutterBridgeRegistry` via ObjC runtime lookup. XCodePostBuild does NOT inject `OnUnityMessage`/`OnUnitySceneLoaded` C callbacks (unlike `flutter_unity_widget`).

### Gradle DSL support

Build.cs detects Kotlin DSL (`build.gradle.kts`) for Flutter 3.29+ and uses the correct syntax:

| Groovy DSL | Kotlin DSL |
|------------|------------|
| `include ':unityLibrary'` | `include(":unityLibrary")` |
| `dirs "..."` | `dirs(file("..."))` |
| `implementation project(':unityLibrary')` | `implementation(project(":unityLibrary"))` |

---

## C# Script Reference

### FlutterBridge

Singleton MonoBehaviour. Entry point for all Flutter -> Unity messages.

```csharp
// Access the singleton
FlutterBridge.Instance

// Events
FlutterBridge.Instance.OnFlutterMessage += (target, method, data) => { };
FlutterBridge.Instance.OnReady += () => { };

// Send ready signal manually (auto-sent on Start if sendReadyOnStart = true)
FlutterBridge.Instance.SendReady();
```

Flutter sends messages via `UnitySendMessage("FlutterBridge", "ReceiveMessage", jsonString)`. FlutterBridge parses the JSON and routes via `MessageRouter`.

### FlutterMessage

DTO for incoming messages. Deserialized via `JsonUtility.FromJson<FlutterMessage>()`.

```csharp
[Serializable]
public class FlutterMessage
{
    public string target;   // Which handler to route to
    public string method;   // Method name
    public string data;     // Payload (string, can be JSON)
}
```

### FlutterMonoBehaviour

Base class for scripts that receive Flutter messages.

```csharp
public abstract class FlutterMonoBehaviour : MonoBehaviour
{
    // Override in Inspector to use a custom target name instead of GameObject.name
    [SerializeField] private string targetName;

    // Implement this to handle messages
    protected abstract void OnFlutterMessage(string method, string data);

    // Send to Flutter (immediate)
    protected void SendToFlutter(string type, string data = "");

    // Send to Flutter (batched per frame)
    protected void SendToFlutterBatched(string type, string data = "");
}
```

### MessageRouter

Static registry for message handlers. `FlutterMonoBehaviour` auto-registers/unregisters.

```csharp
MessageRouter.Register("target", (method, data) => { });
MessageRouter.Unregister("target");
MessageRouter.HasHandler("target");
MessageRouter.Clear();
```

### NativeAPI

Low-level platform bridge. Routes to iOS (`DllImport`) or Android (`AndroidJavaClass`).

```csharp
// Send any JSON string to Flutter
NativeAPI.SendToFlutter("{\"type\":\"my_event\",\"data\":\"hello\"}");

// Notify Flutter about scene load (used by SceneTracker)
NativeAPI.NotifySceneLoaded("SceneName", buildIndex, isLoaded, isValid);
```

**Platform routing:**

| Platform | Mechanism | Target |
|----------|-----------|--------|
| iOS | `[DllImport("__Internal")]` | `SendMessageToFlutter` / `SendSceneLoadedToFlutter` (`extern "C"` in `UnityKitNativeBridge.mm` → ObjC runtime → `FlutterBridgeRegistry`) |
| Android | `AndroidJavaClass` | `com.unity_kit.FlutterBridgeRegistry.sendMessageToFlutter` / `.sendSceneLoadedToFlutter` |
| Editor | `Debug.Log` | Console output for testing |

### MessageBatcher

Attach to FlutterBridge GameObject. Collects messages and flushes as JSON array in `LateUpdate`.

```csharp
var batcher = FlutterBridge.Instance.GetComponent<MessageBatcher>();
batcher.Send("position", "1.0,2.0,3.0");   // Queued
batcher.SendRaw("{\"type\":\"custom\"}");    // Queued
batcher.Flush();                             // Force immediate send
batcher.Clear();                             // Discard pending
```

### SceneTracker

Attach to FlutterBridge GameObject. Automatically calls `NativeAPI.NotifySceneLoaded()` on `SceneManager.sceneLoaded` and sends `scene_unloaded` on `SceneManager.sceneUnloaded`.

### FlutterAddressablesManager

Attach to FlutterBridge GameObject. Requires `ADDRESSABLES_INSTALLED` scripting define. Handles `LoadAsset`, `LoadScene`, `UnloadScene`, and `GetDownloadSize` messages from Flutter.

---

## Troubleshooting

### Unity view never loads on Android (stuck on placeholder)

The app launches but Unity never becomes ready. Logcat shows `Unity view not available after N attempts`.

**Cause:** Unity was exported with only ARMv7 (32-bit) architecture, but the device is arm64 (64-bit). The native `.so` libraries cannot load.

**Fix:** In Unity Editor: **Edit > Project Settings > Player > Android > Other Settings > Target Architectures** — enable **ARM64**. Re-export and redeploy.

### No "Flutter" menu in Unity Editor

- Verify `Assets/Scripts/UnityKit/Editor/Build.cs` exists and compiles without errors
- Check Unity Console for compilation errors
- Editor scripts must be inside an `Editor/` folder

### Android build: ProGuard strips unity_kit classes

Build.cs auto-adds ProGuard rules, but if you're seeing `ClassNotFoundException` for `com.unity_kit.*`:

1. Open `Builds/android/unityLibrary/proguard-unity.txt` (or the deployed copy in `<flutter-app>/android/unityLibrary/proguard-unity.txt`)
2. Verify it contains:
   ```
   -keep class com.unity_kit.** { *; }
   -keep class com.unity3d.player.** { *; }
   ```

### iOS build: Unity not sending messages to Flutter

1. Check that `UnityAppController.mm` was patched (look for `UnityReady` notification)
2. Check Xcode build logs for `SKIP_INSTALL` and `ENABLE_BITCODE` settings
3. Verify `FlutterBridge` GameObject exists in the first scene
4. Verify `sendReadyOnStart` is enabled on the FlutterBridge component

### Messages not reaching Unity from Flutter

1. Verify `FlutterBridge` GameObject exists in the scene and is active
2. Check that your script's target name matches what Flutter sends
3. If using `FlutterMonoBehaviour`, check the `Target Name` field in Inspector (empty = uses GameObject name)
4. Check Unity Console for `[UnityKit] No handler registered for target: xxx` warnings

### Messages not reaching Flutter from Unity

1. Verify you're using `NativeAPI.SendToFlutter()` (not `Debug.Log` or `print`)
2. On Android: check that `com.unity_kit.FlutterBridgeRegistry` is not stripped by ProGuard
3. On iOS: check that `UnityKitNativeBridge.mm` is included in the UnityFramework build phase (provides `SendMessageToFlutter` C symbol)
4. In Editor: messages go to Console only (no Flutter connection in Play Mode)

### IL2CPP stripping removes message DTOs

The `link.xml` file preserves UnityKit DTOs. If you add custom `[Serializable]` classes used with `JsonUtility.FromJson<T>()`, add them to `link.xml`:

```xml
<linker>
    <assembly fullname="Assembly-CSharp">
        <type fullname="YourNamespace.YourClass" preserve="all"/>
    </assembly>
</linker>
```

### Scene loads but Flutter doesn't receive notification

Add `SceneTracker` component to the `FlutterBridge` GameObject. It subscribes to `SceneManager.sceneLoaded` and auto-notifies Flutter.

### Flutter project not detected in Settings

- Verify the path points to the root of a Flutter project (where `pubspec.yaml` is)
- If using env var, make sure it's set before opening Unity: `export UNITY_KIT_FLUTTER_PROJECT=/path/to/app`
- The Settings window shows validation: "pubspec.yaml found" (good) or "no pubspec.yaml" (wrong path)

### NamedBuildTarget / Il2CppCodeGeneration compilation errors

These APIs exist only in Unity 6000+. Build.cs uses `BuildTargetGroup` instead, which works on Unity 2022.3+. If you see these errors, make sure you have the latest version of `Build.cs` from `unity_kit/unity/Assets/Scripts/UnityKit/Editor/`.

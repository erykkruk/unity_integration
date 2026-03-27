# Unity Kit

[![pub package](https://img.shields.io/pub/v/unity_kit.svg)](https://pub.dev/packages/unity_kit)
[![pub points](https://img.shields.io/pub/points/unity_kit)](https://pub.dev/packages/unity_kit/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](unity_kit/LICENSE)

A Flutter plugin for **Unity 3D** integration. Embed Unity content in Flutter apps with typed communication, lifecycle management, asset streaming, and support for Unity 2022.3 LTS through Unity 6.

---

## How It Works

Flutter handles UI (screens, buttons, navigation). Unity handles 3D (rendering, game logic). They run in the same app but are separate worlds -- they talk by sending JSON messages through a native bridge.

```
Flutter (Dart)                                    Unity (C#)
  UI, screens,          JSON messages               3D rendering,
  business logic   <=========================>      game logic
                    native bridge (iOS/Android)
```

**There are no direct method calls.** Everything goes through serialized JSON over the platform bridge. Flutter never calls C# directly, and Unity never calls Dart directly.

---

## Repository Structure

```
.
├── unity_kit/              # Flutter plugin package (published to pub.dev)
│   ├── lib/                # Dart source code
│   ├── android/            # Android native layer (Kotlin)
│   ├── ios/                # iOS native layer (Swift)
│   ├── unity/              # C# scripts for Unity side
│   ├── example/            # Example Flutter app
│   ├── test/               # Test suite (35 files, 640+ tests)
│   └── doc/                # API reference & asset streaming guide
├── doc/                    # Detailed guides
│   ├── unity-export.md     # Step-by-step Unity export guide
│   ├── unity_integrations.md     # Content loading methods (scenes, Addressables, etc.)
│   ├── android-integration.md    # Android native architecture & known issues
│   ├── ios-integration.md        # iOS native architecture & known issues
│   └── architecture.md           # Overall architecture overview
└── .github/workflows/      # CI/CD (auto-tag + pub.dev publish)
```

---

## Key Features

| Feature | What it does |
|---------|-------------|
| **Typed Bridge** | `UnityMessage` objects instead of raw strings. Structured, type-safe communication. |
| **Lifecycle Management** | State machine: `uninitialized` -> `ready` -> `paused` -> `disposed`. Invalid transitions throw exceptions. |
| **Readiness Guard** | Messages sent before Unity is ready get queued and auto-flushed when the engine starts. Nothing is silently dropped. |
| **Message Batching** | Groups rapid-fire messages into single native calls (~16ms windows). |
| **Message Throttling** | Rate-limits outgoing messages with configurable strategies (drop / keepLatest / keepFirst). |
| **Asset Streaming** | Download Unity bundles from CDN, cache locally with SHA-256 verification, load via Addressables. |
| **Unity 6 Support** | Reflection-based player creation handles both legacy `UnityPlayer` and Unity 6's `UnityPlayerForActivityOrService`. |
| **Platform Views** | Android (Virtual Display) and iOS (UiKitView composition). |

---

## Quick Start

### 1. Add dependency

```yaml
# pubspec.yaml
dependencies:
  unity_kit: ^0.9.2
```

### 2. Minimal Flutter code

```dart
import 'package:unity_kit/unity_kit.dart';

final bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);
await bridge.initialize();

UnityView(
  bridge: bridge,
  config: const UnityConfig(sceneName: 'MainScene'),
  onReady: (bridge) => bridge.send(UnityMessage.command('StartGame')),
  onMessage: (msg) => print('Unity says: ${msg.type}'),
);
```

### 3. Unity side

Copy `unity_kit/unity/Assets/Scripts/UnityKit/` into your Unity project. A `FlutterBridge` GameObject auto-creates on scene load and handles all communication.

```csharp
// Receive messages from Flutter
public class MyHandler : FlutterMonoBehaviour
{
    protected override void OnFlutterMessage(string method, string data)
    {
        switch (method)
        {
            case "StartGame":
                // do something
                NativeAPI.SendToFlutter("{\"type\":\"game_started\"}");
                break;
        }
    }
}
```

---

## Communication

### Message Formats

**Flutter -> Unity (routed to a handler):**
```json
{"target": "MyHandler", "method": "StartGame", "data": "params"}
```

**Unity -> Flutter (typed event):**
```json
{"type": "game_started", "data": {"score": 100}}
```

### Naming Convention

| Direction | Casing | Example |
|-----------|--------|---------|
| Flutter -> Unity (commands) | `PascalCase` | `LoadToy`, `StartGame` |
| Unity -> Flutter (responses) | `snake_case` | `toy_loaded`, `game_started` |

### How to Add a New Command

**Unity side:**
1. Add a `case` in your handler (or create a new `FlutterMonoBehaviour`)
2. Send responses via `NativeAPI.SendToFlutter(json)`

**Flutter side:**
1. Send: `bridge.send(UnityMessage.to('HandlerName', 'MethodName', data))`
2. Listen: `bridge.messageStream.listen((msg) => ...)`

The bridge never changes. You define a JSON contract (command name + payload), implement on both sides, done.

---

## Unity Export Workflow

Unity project and Flutter project are separate. Unity exports a library module, which gets copied to the Flutter project.

```
Unity Project                              Flutter Project
  Assets/, Scenes/                           android/unityLibrary/  <-- artifact
  Scripts/UnityKit/                          ios/UnityLibrary/      <-- artifact
  Builds/ (export artifacts)  -- copy -->    lib/, pubspec.yaml
```

### Export steps

1. Open Unity Editor with your project
2. **Flutter > Export Android (Debug)** or **Flutter > Export iOS (Debug)**
3. Artifacts appear in `Builds/`
4. Set Flutter project path in **Flutter > Settings** for auto-deploy, or copy manually

### CI pipeline

```bash
Unity -quit -batchmode -projectPath /path/to/project \
  -executeMethod UnityKit.Editor.Build.ExportAndroidRelease
```

See **[Unity Export Guide](doc/unity-export.md)** for full details.

---

## Asset Streaming (Addressables)

For downloading 3D content from a server at runtime:

```
1. Flutter downloads content_manifest.json from CDN
2. User selects a toy/asset in the UI
3. Flutter downloads the .bundle file to local cache (SHA-256 verified)
4. Flutter tells Unity: "cache is at /path" (SetCachePath)
5. Flutter tells Unity: "load asset with key 'alphie'" (LoadToyRemote)
6. Unity Addressables loads from local cache (not from network again)
7. Unity sends "toy_loaded" back to Flutter
```

### Building Addressables

1. **Setup (one-time):** `Flutter > Setup Addressables`
2. **Add asset:** place prefab in Addressables group, set address key
3. **Build:** `Flutter > Build Addressables` (generates bundles + `content_manifest.json`)
4. **Upload:** push `ServerData/[BuildTarget]/` to CDN

See **[Asset Streaming Guide](unity_kit/doc/asset-streaming.md)** for manifest format and configuration.

---

## Development

```bash
cd unity_kit && dart pub get       # Install dependencies
cd unity_kit && flutter test       # Run tests
cd unity_kit && dart analyze       # Analyze
cd unity_kit && dart format .      # Format
cd unity_kit && dart pub publish --dry-run  # Publish check
```

---

## Guides

| Guide | What's in it |
|-------|-------------|
| **[Unity Export](doc/unity-export.md)** | Step-by-step: install scripts, configure build, export for Android/iOS/WebGL |
| **[Content Loading](doc/unity_integrations.md)** | All methods: scenes, prefabs, AssetBundles, Addressables, glTF, AR |
| **[Android Integration](doc/android-integration.md)** | Android native layer: Unity 6 patterns, reflection, touch, rendering activation |
| **[iOS Integration](doc/ios-integration.md)** | iOS native layer: UnityFramework, .mm bridge, Metal crash prevention |
| **[Architecture](doc/architecture.md)** | Overall design: bridge, lifecycle, streams, exceptions |
| **[Asset Streaming](unity_kit/doc/asset-streaming.md)** | Addressables vs AssetBundles, manifest format, cache management |
| **[API Reference](unity_kit/doc/api.md)** | Class signatures, parameters, code examples |
| **[FAQ](doc/faq.md)** | Common problems and solutions |

---

## FAQ (Common Problems)

See **[doc/faq.md](doc/faq.md)** for the full list. Here are the top issues:

### Black screen after Unity loads (Android)

Unity needs an explicit "refocus" after attaching to the view: `windowFocusChanged(true)` + `pause()` + `resume()`. This is handled by `unity_kit` automatically. If you see a black screen, check that you're using the latest version.

### Touch not working (Android)

Unity's New Input System requires `InputDevice.SOURCE_TOUCHSCREEN` on touch events. The `UnityContainerLayout` in `unity_kit` fixes this. If touch doesn't work, make sure you're not overriding the touch handling.

### White/blank screen (iOS)

Usually a timing issue: Unity's Metal renderer needs a non-zero view frame before initialization. `unity_kit` polls with `waitForNonZeroFrame()`. If it persists, ensure the `UnityView` widget has a non-zero size in the layout.

### Release build works differently than debug (Android)

ProGuard/R8 can strip classes used via reflection or JNI. `unity_kit`'s `Build.cs` auto-adds ProGuard keep rules during export. If you see silent failures in release, verify `proguard-unity.txt` contains keep rules for `com.unity_kit.**` and `com.unity3d.player.**`.

### Messages not reaching Unity / Flutter

1. Check `FlutterBridge` GameObject exists in the first scene
2. Check your handler's target name matches what Flutter sends
3. Check Unity Console for `[UnityKit] No handler registered for target: xxx`
4. On iOS: verify `UnityKitNativeBridge.mm` is in `Assets/Plugins/iOS/`

### Unity 6 compatibility

`unity_kit` uses reflection to detect Unity 6's `UnityPlayerForActivityOrService` class automatically. No manual configuration needed. If you're using Unity 6 and see issues, check the **[Android Integration](doc/android-integration.md)** guide for constructor signature details.

---

## Roadmap to 1.0

- 3D model loading utilities and prefab management helpers
- Full step-by-step tutorial covering the complete integration flow
- Additional example scenes and sample Unity project

## License

MIT License -- see [unity_kit/LICENSE](unity_kit/LICENSE) for details.

---

<p align="center">
  Created by <a href="https://ravenlab.tech">Eryk Kruk</a>
</p>

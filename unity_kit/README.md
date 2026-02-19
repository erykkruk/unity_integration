# unity_kit

Zero external dependencies Flutter plugin for Unity 3D integration. Typed bridge
communication, lifecycle management, readiness guard, message batching/throttling,
and asset streaming with cache management.

[![pub package](https://img.shields.io/pub/v/unity_kit.svg)](https://pub.dev/packages/unity_kit)
[![pub points](https://img.shields.io/pub/points/unity_kit)](https://pub.dev/packages/unity_kit/score)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.2+-blue.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)](https://flutter.dev)
[![Unity](https://img.shields.io/badge/Unity-2022.3_LTS+-black.svg)](https://unity.com)

---

## Features

| Feature | Description |
|---------|-------------|
| **Typed Bridge** | Abstract `UnityBridge` interface with `UnityMessage` for structured Flutter-Unity communication |
| **Lifecycle Management** | State machine with enforced transitions (`uninitialized` -> `ready` -> `paused` -> `resumed` -> `disposed`) |
| **Readiness Guard** | Queues messages before Unity is ready, auto-flushes when the engine starts |
| **Message Batching** | Coalesces rapid-fire messages into batches to reduce native call overhead |
| **Message Throttling** | Rate-limits outgoing messages with configurable strategy (drop, keepLatest, keepFirst) |
| **Asset Streaming** | Manifest-based content downloading with SHA-256 integrity, local caching, and Unity Addressables integration |
| **Platform Views** | Android (HybridComposition / VirtualDisplay / TextureLayer) and iOS (UiKitView) support |
| **Scene Tracking** | Automatic scene load/unload events streamed from Unity to Flutter |
| **Message Routing** | Register type-specific callbacks with `MessageHandler` for clean event dispatching |
| **Structured Exceptions** | Exception hierarchy: `UnityKitException` -> `BridgeException`, `CommunicationException`, `LifecycleException`, `EngineNotReadyException` |

---

## Installation

### 1. Add dependency

```yaml
# pubspec.yaml
dependencies:
  unity_kit: ^0.9.1
```

Or install via command line:

```bash
flutter pub add unity_kit
```

### 2. Android setup

**`android/app/build.gradle`**:

```groovy
android {
    defaultConfig {
        minSdkVersion 22 // Unity requires API 22+
        ndk {
            abiFilters 'armeabi-v7a', 'arm64-v8a'
        }
    }
}
```

**`android/build.gradle`** -- add the Unity export as a flat directory:

```groovy
allprojects {
    repositories {
        flatDir {
            dirs "${project(':unityLibrary').projectDir}/libs"
        }
    }
}
```

**`android/settings.gradle`** -- include the Unity library:

```groovy
include ':unityLibrary'
project(':unityLibrary').projectDir = file('./unityLibrary')
```

### 3. iOS setup

**`ios/Podfile`**:

```ruby
platform :ios, '13.0'

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_BITCODE'] = 'NO'
    end
  end
end
```

Export the Unity project as an iOS framework and include it in your Runner workspace.

### 4. Unity setup

1. Open your Unity project (2022.3 LTS or later).
2. Copy the C# scripts from `unity/Assets/Scripts/UnityKit/` into your Unity `Assets/` folder.
3. Create an empty `GameObject` named `FlutterBridge` in your initial scene.
4. Attach the `FlutterBridge` component and (optionally) `SceneTracker` and `MessageBatcher`.
5. Mark the GameObject as `DontDestroyOnLoad` (this is automatic via the `FlutterBridge` script).
6. Build for the target platform and export.

---

## Quick Start

```dart
import 'package:unity_kit/unity_kit.dart';

// 1. Create the bridge (independent of any widget)
final bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);
await bridge.initialize();

// 2. Embed the Unity view
UnityView(
  bridge: bridge,
  config: const UnityConfig(sceneName: 'MainScene'),
  placeholder: const UnityPlaceholder(message: 'Loading 3D...'),
  onReady: (bridge) {
    bridge.send(UnityMessage.command('StartGame'));
  },
  onMessage: (message) {
    print('From Unity: ${message.type}');
  },
  onSceneLoaded: (scene) {
    print('Scene loaded: ${scene.name}');
  },
);

// 3. Clean up
await bridge.dispose();
```

The bridge is intentionally independent of the widget. You can create it in a
service layer, pass it to multiple widgets, and dispose it on your own terms.
When `UnityView` receives an external bridge, it **never** disposes it -- the
widget only disposes bridges it creates internally.

---

## Communication

### Flutter to Unity

```dart
// Simple command (sends to FlutterBridge.ReceiveMessage by default)
await bridge.send(UnityMessage.command('LoadScene', {'name': 'Level1'}));

// Target a specific GameObject and method
await bridge.send(UnityMessage.to('EnemyManager', 'SpawnWave', {'count': 5}));

// Queue until Unity is ready (auto-flushes when engine starts)
await bridge.sendWhenReady(UnityMessage.command('Init', {'userId': '123'}));
```

### Unity to Flutter

```dart
// Listen to all messages
bridge.messageStream.listen((msg) {
  switch (msg.type) {
    case 'score_updated':
      final score = msg.data?['score'] as int?;
      // update UI
    case 'game_over':
      // show results
  }
});

// Listen to lifecycle events
bridge.eventStream.listen((event) {
  print('Event: ${event.type} at ${event.timestamp}');
});

// Listen to scene loads
bridge.sceneStream.listen((scene) {
  print('Scene: ${scene.name}, loaded: ${scene.isLoaded}');
});

// Listen to lifecycle state changes
bridge.lifecycleStream.listen((state) {
  print('State: $state, active: ${state.isActive}');
});
```

### Type-specific handlers

```dart
final handler = MessageHandler();
handler.on('score_updated', (msg) => updateScore(msg.data));
handler.on('game_over', (msg) => showGameOver());
handler.on('error', (msg) => handleError(msg.data));

handler.listenTo(bridge.messageStream);

// Cleanup
handler.dispose();
```

---

## Lifecycle Management

The Unity player follows a strict state machine. Invalid transitions throw
`LifecycleException`.

```
                                +--------+
                                | disposed |
                                +--------+
                                  ^  ^  ^
                                  |  |  |
  +---------------+    +--------+ |  |  |  +--------+    +---------+
  | uninitialized |--->| init.. |-+  |  +--| paused |<-->| resumed |
  +---------------+    +--------+    |     +--------+    +---------+
                           |         |        ^
                           v         |        |
                        +-------+----+--------+
                        | ready |
                        +-------+
```

**Valid transitions:**

| From | To |
|------|-----|
| `uninitialized` | `initializing` |
| `initializing` | `ready`, `disposed` |
| `ready` | `paused`, `disposed` |
| `paused` | `resumed`, `disposed` |
| `resumed` | `paused`, `disposed` |
| `disposed` | *(terminal)* |

Access lifecycle state:

```dart
bridge.currentState; // UnityLifecycleState.ready
bridge.isReady;      // true

await bridge.pause();
await bridge.resume();
await bridge.unload(); // resets to uninitialized, keeps process
await bridge.dispose(); // terminal, cannot reuse
```

---

## Configuration

```dart
const config = UnityConfig(
  sceneName: 'GameScene',       // Scene to load on init (default: 'MainScene')
  fullscreen: false,            // Fullscreen Unity rendering (default: false)
  unloadOnDispose: true,        // Unload Unity on widget dispose (default: true)
  hideStatusBar: false,         // Hide system status bar (default: false)
  runImmediately: true,         // Start player immediately (default: true)
  targetFrameRate: 60,          // Target FPS (default: 60)
  platformViewMode: PlatformViewMode.hybridComposition, // Android only
);

// Convenience factory for fullscreen
final fullscreenConfig = UnityConfig.fullscreen(sceneName: 'GameScene');

// Copy with modifications
final modified = config.copyWith(targetFrameRate: 30);
```

### PlatformViewMode (Android only)

| Mode | Performance | Compatibility | Notes |
|------|-------------|---------------|-------|
| `hybridComposition` | Good | Best | Default. Recommended for most cases. |
| `virtualDisplay` | Better | Good | Potential z-ordering and input issues. |
| `textureLayer` | Best | Limited | Limited platform support. |

---

## Asset Streaming

`unity_kit` includes a full asset streaming pipeline that downloads content
bundles from a CDN, caches them locally with SHA-256 integrity verification,
and tells Unity Addressables to load from the local cache.

### Manifest format

Host a JSON manifest on your CDN:

```json
{
  "version": "1.0.0",
  "baseUrl": "https://cdn.example.com/bundles",
  "platform": "android",
  "bundles": [
    {
      "name": "core",
      "url": "https://cdn.example.com/bundles/core.bin",
      "sizeBytes": 5242880,
      "sha256": "a1b2c3...",
      "isBase": true
    },
    {
      "name": "characters",
      "url": "https://cdn.example.com/bundles/characters.bin",
      "sizeBytes": 10485760,
      "sha256": "d4e5f6...",
      "isBase": false,
      "group": "characters",
      "dependencies": ["core"]
    }
  ]
}
```

### Usage

```dart
// 1. Create streaming controller
final streaming = StreamingController(
  bridge: bridge,
  manifestUrl: 'https://cdn.example.com/manifest.json',
);

// 2. Initialize (fetches manifest, sets up cache, informs Unity)
await streaming.initialize();

// 3. Track progress
streaming.downloadProgress.listen((progress) {
  print('${progress.bundleName}: ${progress.percentageString}');
  print('Speed: ${progress.speedString}, ETA: ${progress.etaString}');
});

streaming.errors.listen((error) {
  print('Error: ${error.type} - ${error.message}');
});

// 4. Preload base content
await streaming.preloadContent();

// 5. Load a specific bundle on demand
await streaming.loadBundle('characters');

// 6. Load a Unity scene via Addressables
await streaming.loadScene('BattleArena', loadMode: 'Additive');

// 7. Cache management
final cached = streaming.getCachedBundles();
final size = streaming.getCacheSize();
final isCached = streaming.isBundleCached('characters');
await streaming.clearCache();

// 8. Dispose
await streaming.dispose();
```

### ContentDownloader (advanced)

For more granular control over downloads (retries, concurrency, cancellation):

```dart
final downloader = ContentDownloader(
  cacheManager: CacheManager(),
  maxRetries: 3,
  maxConcurrency: 3,
);

await for (final progress in downloader.downloadBundle(bundle)) {
  print('${progress.percentageString} - ${progress.speedString}');
}

// Cancel specific download
downloader.cancelDownload('characters');
downloader.cancelAllDownloads();

downloader.dispose();
```

### Unity asset loading

`unity_kit` supports two asset loading strategies on the Unity side:

| Strategy | Unity component | When to use |
|----------|----------------|-------------|
| **Addressables** | `FlutterAddressablesManager` | Recommended. Requires Unity Addressables package. |
| **Raw AssetBundles** | `FlutterAssetBundleManager` | Simpler setup, no extra Unity packages needed. |

Both use the same `StreamingController` API on the Flutter side. See **[doc/asset-streaming.md](doc/asset-streaming.md)** for the full setup guide.

#### Addressables setup

1. Install the **Addressables** package in Unity (Window > Package Manager).
2. Add the `ADDRESSABLES_INSTALLED` scripting define symbol:
   - Edit > Project Settings > Player > Other Settings > Scripting Define Symbols.
3. Attach `FlutterAddressablesManager` to the same `FlutterBridge` GameObject.
4. Mark your assets and scenes as Addressable in the Unity Editor.
5. Build Addressables content (Window > Asset Management > Addressables > Build).

#### Raw AssetBundles setup

1. Attach `FlutterAssetBundleManager` to the `FlutterBridge` GameObject.
2. Build AssetBundles (Window > AssetBundles > Build).
3. Host bundles on a CDN and create a manifest (see [doc/asset-streaming.md](doc/asset-streaming.md)).

When Flutter calls `streaming.loadBundle('characters')`, the flow is:

```
Flutter                          Native Cache                  Unity
  |                                  |                           |
  |-- download bundle ------------->|                           |
  |                                  |-- write to disk          |
  |-- sendWhenReady(LoadAsset) -----|-------------------------->|
  |                                  |                           |
  |                                  |<--- Addressables checks  |
  |                                  |     local cache first    |
  |                                  |                           |
  |<------- asset_loaded response --|---------------------------|
```

---

## Unity C# Setup

### FlutterBridge (required)

Singleton `MonoBehaviour` that receives all messages from Flutter. Attach to a
`GameObject` named `FlutterBridge` in your startup scene.

```csharp
// FlutterBridge auto-sends a "ready" signal on Start().
// You can disable this with sendReadyOnStart = false in the Inspector.
```

### FlutterMonoBehaviour (recommended)

Base class for any `MonoBehaviour` that communicates with Flutter. Auto-registers
with `MessageRouter` on enable, auto-unregisters on disable.

```csharp
using UnityKit;

public class EnemyManager : FlutterMonoBehaviour
{
    protected override void OnFlutterMessage(string method, string data)
    {
        switch (method)
        {
            case "SpawnWave":
                // parse data, spawn enemies
                break;
            case "Reset":
                // reset game state
                break;
        }
    }

    private void OnWaveCleared()
    {
        // Direct send
        SendToFlutter("wave_cleared", "{\"wave\": 3}");

        // Batched send (via MessageBatcher component on FlutterBridge)
        SendToFlutterBatched("score_updated", "{\"score\": 1500}");
    }
}
```

### MessageRouter

Static registry that routes messages from `FlutterBridge.ReceiveMessage()` to
the correct `FlutterMonoBehaviour` by target name. Manual registration is also
possible:

```csharp
MessageRouter.Register("CustomTarget", (method, data) => {
    Debug.Log($"Received: {method} with {data}");
});

MessageRouter.Unregister("CustomTarget");
```

### SceneTracker

Attach alongside `FlutterBridge` to automatically notify Flutter when scenes
load or unload. No configuration needed.

### MessageBatcher (C#)

Batches outgoing Unity-to-Flutter messages per frame. All queued messages are
sent as a JSON array in `LateUpdate()`.

```csharp
var batcher = FlutterBridge.Instance.GetComponent<MessageBatcher>();
batcher.Send("position_update", "{\"x\": 1.5}");
batcher.Send("rotation_update", "{\"y\": 90}");
// Both sent as a single batch at end of frame
```

### NativeAPI

Low-level native bridge. You typically do not call this directly -- use
`FlutterMonoBehaviour.SendToFlutter()` or `MessageBatcher.Send()` instead.

---

## Performance

### Message Batching (Dart)

Reduces native call overhead by coalescing messages within a time window.
Messages with the same `gameObject:method` key are deduplicated (last value wins).

```dart
final bridge = UnityBridgeImpl(
  platform: UnityKitPlatform.instance,
  batcher: MessageBatcher(
    flushInterval: const Duration(milliseconds: 16), // ~1 frame at 60fps
    maxBatchSize: 10,                                 // Flush immediately at 10
    onFlush: (messages) async {
      for (final msg in messages) {
        await platform.postMessage(msg.gameObject, msg.method, msg.toJson());
      }
    },
  ),
);

// Stats
print('Batched: ${batcher.totalBatched}');
print('Flushed: ${batcher.totalFlushed}');
print('Avg batch size: ${batcher.averageBatchSize}');
```

### Message Throttling (Dart)

Rate-limits messages to prevent flooding Unity.

```dart
final bridge = UnityBridgeImpl(
  platform: UnityKitPlatform.instance,
  throttler: MessageThrottler(
    window: const Duration(milliseconds: 100),
    strategy: ThrottleStrategy.keepLatest,
  ),
);
```

| Strategy | Behavior |
|----------|----------|
| `ThrottleStrategy.drop` | Drop all messages during the window |
| `ThrottleStrategy.keepLatest` | Keep only the newest message (default) |
| `ThrottleStrategy.keepFirst` | Keep only the first message, drop subsequent |

```dart
// Stats
print('Total: ${throttler.totalThrottled}');
print('Sent: ${throttler.totalSent}');
print('Dropped: ${throttler.totalDropped}');
print('Currently throttling: ${throttler.isThrottling}');
```

---

## Resolved Issues

Common Flutter + Unity integration problems and how `unity_kit` solves them:

| # | Issue | Solution |
|---|-------|----------|
| 1 | Bridge destroyed when widget rebuilds | Bridge is independent of widget. External bridges survive widget disposal. |
| 2 | Messages sent before Unity is ready | `ReadinessGuard` queues messages; `sendWhenReady()` auto-flushes on ready. |
| 3 | App crash on background/foreground | `UnityLifecycleMixin` and `UnityView` auto-pause/resume on app lifecycle. |
| 4 | Untyped string messages | `UnityMessage` with `type`, `data`, `gameObject`, `method` fields and factory constructors. |
| 5 | Message flooding causes frame drops | `MessageThrottler` rate-limits outgoing messages; `MessageBatcher` coalesces. |
| 6 | No scene load tracking | `SceneTracker` (C#) + `sceneStream` (Dart) auto-report scene events. |
| 7 | Invalid lifecycle transitions | `LifecycleManager` enforces state machine; throws `LifecycleException` on invalid transitions. |
| 8 | Large asset download blocks startup | `StreamingController` downloads content in background with progress tracking. |
| 9 | Cache integrity issues | `CacheManager` stores SHA-256 hashes, supports `verifyCache()` for integrity checks. |
| 10 | Platform view rendering issues on Android | `PlatformViewMode` enum with three modes to tune rendering vs. compatibility. |

---

## Migration from flutter_unity_widget

| flutter_unity_widget | unity_kit |
|---------------------|-----------|
| `UnityWidget(onUnityCreated: ...)` | `UnityView(bridge: bridge, onReady: ...)` |
| `controller.postMessage(go, method, data)` | `bridge.send(UnityMessage.to(go, method, data))` |
| `onUnityMessage: (msg) => ...` | `bridge.messageStream.listen(...)` or `onMessage:` callback |
| No lifecycle management | `bridge.pause()`, `bridge.resume()`, `bridge.unload()` |
| No readiness guard | `bridge.sendWhenReady(message)` |
| No message batching | `MessageBatcher(flushInterval: ..., onFlush: ...)` |
| No asset streaming | `StreamingController(bridge: ..., manifestUrl: ...)` |
| `UnityMessageManager.Instance.SendMessageToFlutter(msg)` | `NativeAPI.SendToFlutter(json)` or `FlutterMonoBehaviour.SendToFlutter(type, data)` |

---

## API Reference

Full API documentation with class signatures, parameters, and code examples:
**[doc/api.md](doc/api.md)**

---

## Roadmap to 1.0

This is a **pre-release** (`0.9.x`). Before `1.0.0`, the following is planned:

- 3D model loading utilities and prefab management helpers
- Full step-by-step tutorial covering the complete integration flow (Unity export, Flutter setup, bridge communication, asset streaming)
- Additional example scenes and sample Unity project

API may change between `0.9.x` releases. Pin your version if you need stability.

---

## License

See [LICENSE](LICENSE) for details.

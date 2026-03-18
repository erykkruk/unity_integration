# Unity Kit

[![pub package](https://img.shields.io/pub/v/unity_kit.svg)](https://pub.dev/packages/unity_kit)
[![pub points](https://img.shields.io/pub/points/unity_kit)](https://pub.dev/packages/unity_kit/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](unity_kit/LICENSE)

A Flutter plugin for **Unity 3D** integration. Typed bridge communication, lifecycle management, readiness guard, message batching/throttling, and asset streaming with cache management.

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
├── doc/                    # Public guides
│   ├── unity-export.md     # Step-by-step Unity export guide
│   ├── unity_integrations.md     # Content loading & generation methods
│   ├── android-integration.md    # Android native architecture & known issues
│   ├── ios-integration.md        # iOS native architecture & known issues
│   └── architecture.md           # Overall architecture overview
└── .github/workflows/      # CI/CD (auto-tag + pub.dev publish)
```

## Key Features

| Feature | Description |
|---------|-------------|
| **Typed Bridge** | `UnityBridge` interface with `UnityMessage` for structured Flutter-Unity communication |
| **Lifecycle Management** | State machine: `uninitialized` → `ready` → `paused` → `resumed` → `disposed` |
| **Readiness Guard** | Queues messages before Unity is ready, auto-flushes on engine start |
| **Message Batching** | Coalesces rapid-fire messages (~16ms windows) to reduce native call overhead |
| **Message Throttling** | Rate-limits outgoing messages (drop / keepLatest / keepFirst) |
| **Asset Streaming** | Manifest-based downloading with SHA-256 integrity, local caching, Addressables + AssetBundle support |
| **Platform Views** | Android (HybridComposition / VirtualDisplay / TextureLayer) and iOS (UiKitView) |
| **Gesture Controls** | Configurable gesture recognizers for the Unity view |

## Quick Start

```yaml
# pubspec.yaml
dependencies:
  unity_kit: ^0.9.2
```

```dart
import 'package:unity_kit/unity_kit.dart';

final bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);
await bridge.initialize();

UnityView(
  bridge: bridge,
  config: const UnityConfig(sceneName: 'MainScene'),
  onReady: (bridge) => bridge.send(UnityMessage.command('StartGame')),
);
```

Full documentation: **[unity_kit/README.md](unity_kit/README.md)**

## Development

```bash
# Install dependencies
cd unity_kit && dart pub get

# Run tests
cd unity_kit && flutter test

# Analyze
cd unity_kit && dart analyze

# Format
cd unity_kit && dart format .

# Publish dry-run
cd unity_kit && dart pub publish --dry-run
```

## Guides

- **[Unity Export Guide](doc/unity-export.md)** — Step-by-step: install scripts, configure build, export for Android/iOS
- **[Unity Content Loading](doc/unity_integrations.md)** — All methods: scenes, prefabs, AssetBundles, Addressables, glTF, runtime mesh generation, AR
- **[Android Integration](doc/android-integration.md)** — Native layer architecture, Unity 6000 patterns, known issues & workarounds
- **[iOS Integration](doc/ios-integration.md)** — Native layer architecture, Swift bridge, known issues & workarounds
- **[Architecture Overview](doc/architecture.md)** — Overall design, component diagram, data flow
- **[Asset Streaming Guide](unity_kit/doc/asset-streaming.md)** — Addressables vs AssetBundles setup, manifest format
- **[API Reference](unity_kit/doc/api.md)** — Class signatures, parameters, code examples

## Roadmap to 1.0

- 3D model loading utilities and prefab management helpers
- Full step-by-step tutorial covering the complete integration flow
- Additional example scenes and sample Unity project

## License

MIT License — see [unity_kit/LICENSE](unity_kit/LICENSE) for details.

---

<p align="center">
  Created by <a href="https://ravenlab.tech">Eryk Kruk</a>
</p>

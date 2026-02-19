# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.1] - 2026-02-20

### Fixed

- Fixed `.pubignore` excluding `models/` directory from published package, causing 159 analysis errors on pub.dev.
- Removed unused `connectivity_plus` dependency.

## [0.9.0] - 2026-02-19

### Added

- Gesture controls for `UnityView` (`gestureRecognizers` parameter).
- CocoaPods support for iOS integration.
- Target frame rate configuration (`UnityConfig.targetFrameRate`).
- Touch event handling for Android and iOS.
- Flutter Android lifecycle integration.
- Core bridge: `UnityBridge`, `UnityBridgeImpl` with typed messaging.
- Lifecycle management: 6-state machine (`uninitialized` → `ready` → `paused` → `resumed` → `disposed`).
- Readiness guard: auto-queue messages until Unity is ready.
- Message batching (~16ms windows, coalescing).
- Message throttling (3 strategies: `drop`, `keepLatest`, `keepFirst`).
- Asset streaming: manifest-based, SHA-256 integrity, caching.
- Content downloading with exponential backoff.
- Addressables and AssetBundle loaders.
- `UnityView` widget with platform views (Android HybridComposition + iOS UiKitView).
- `UnityPlaceholder` loading widget.
- `UnityLifecycleMixin` for app pause/resume handling.
- Typed exception hierarchy (`UnityKitException`, `BridgeException`, `CommunicationException`, `LifecycleException`, `EngineNotReadyException`).
- `UnityConfig`, `UnityMessage`, `SceneInfo` models.
- Platform abstraction via `MethodChannel`.
- C# Unity scripts (`FlutterBridge`, `MessageRouter`, `MessageBatcher`, `SceneTracker`, `NativeAPI`, `FlutterMonoBehaviour`).
- Comprehensive test suite (35 files, ~9000 lines).
- API documentation and asset streaming guide.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-03-27

### Changed

- **Stable release** — API is now considered stable. Follows Semantic Versioning from this point.
- `_RoutedUnityMessage` now exposes logical `gameObject`, `method`, `type`, and `data` properties matching the actual target (e.g. `FlutterAddressablesManager`), while routing through `FlutterBridge.ReceiveMessage` at the native layer via `nativeGameObject`/`nativeMethod`.

### Added

- `UnityMessage.nativeGameObject` and `UnityMessage.nativeMethod` getters for accessing the native `UnitySendMessage` target separately from the logical message properties.
- `UnityAssetLoader.loadContentCatalogMessage` — request Unity to load a remote content catalog by URL (Addressables).
- "Why Addressables?" section in README — explains how dynamic content delivery keeps app size ~100 MB instead of 500 MB+.

### Fixed

- All 22 previously failing tests in `streaming/` and `loaders/` now pass — routed messages correctly expose target info through standard `UnityMessage` properties.

## [0.9.2] - 2026-03-18

### Fixed

- **Android display bug:** Unity view no longer renders on top of all Flutter widgets, covering the entire screen regardless of layout bounds ([#1](https://github.com/erykkruk/flutter_unity_kit/issues/1)).
  - Switched Android rendering from Virtual Display (`AndroidView`) to Hybrid Composition (`PlatformViewLink` + `initExpensiveAndroidView`) for correct z-ordering and bounds clipping.
  - Applied `setZOrderOnTop(false)` on Unity's `SurfaceView` after attachment.
  - Added delayed re-focus (500ms) to ensure rendering starts after Hybrid Composition finishes surface setup.

### Documentation

- Added ARM64 export requirement to unity-export.md — exporting only ARMv7 causes Unity player to silently fail on arm64 devices.
- Added troubleshooting entry for "Unity view never loads on Android".

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

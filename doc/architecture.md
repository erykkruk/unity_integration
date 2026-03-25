# unity_kit Architecture Overview

This document describes the architecture, design decisions, and key patterns used in `unity_kit`.

---

## Table of Contents

- [Overview](#overview)
- [Library Architecture](#library-architecture)
- [Bridge Design](#bridge-design)
- [Lifecycle State Machine](#lifecycle-state-machine)
- [Communication Protocol](#communication-protocol)
- [Platform Layer](#platform-layer)
- [Asset Streaming Pipeline](#asset-streaming-pipeline)
- [Exception Hierarchy](#exception-hierarchy)
- [Design Decisions](#design-decisions)
- [Comparison with Alternatives](#comparison-with-alternatives)

---

## Overview

`unity_kit` is a Flutter plugin for Unity 3D integration. It provides typed bridge communication, lifecycle management, readiness guards, message batching/throttling, and asset streaming with cache management.

**Tech Stack:**

| Category | Technology | Version |
|----------|-----------|---------|
| Language | Dart | >=3.0.0 <4.0.0 |
| Framework | Flutter | >=3.0.0 |
| Unity Bridge | flutter_unity_widget (conceptual) | Custom native |
| Game Engine | Unity | 2022.3 LTS+ / Unity 6000 |
| Unity Language | C# | .NET Standard 2.1 |

---

## Library Architecture

```
Public API (lib/unity_kit.dart - barrel export)
    |
Widgets (lib/src/widgets/) - Flutter StatefulWidgets wrapping Unity PlatformView
    |
Bridge (lib/src/bridge/) - Abstract interface for Flutter <-> Unity communication
    |
Models (lib/src/models/) - Typed configs, messages, events, enums
    |
Streaming (lib/src/streaming/) - Asset download, caching, Addressables integration
    |
Platform (lib/src/platform/) - MethodChannel implementation, native interface
    |
Exceptions (lib/src/exceptions/) - Structured error types
    |
Utils (lib/src/utils/) - Internal constants, logging (NOT exported)
```

### Key Design Principles

1. **Abstract interface** for the bridge -- swappable for testing, mockable
2. **Factory constructors** on models for common use cases
3. **Barrel exports** at each module level + top-level library file
4. **Bridge independent of widget** -- the bridge is a service, the widget is just a view
5. **Streams for events** -- `messageStream`, `eventStream`, `sceneStream`, `lifecycleStream`

---

## Bridge Design

The bridge follows a layered composition pattern:

```
UnityBridgeImpl (facade)
+-- LifecycleManager      (state machine with enforced transitions)
+-- ReadinessGuard         (queues messages until Unity is ready)
+-- MessageHandler         (routes messages by type to registered callbacks)
+-- MessageBatcher?        (optional - coalesces rapid messages)
+-- MessageThrottler?      (optional - rate-limits outgoing messages)
+-- UnityKitPlatform       (native communication via MethodChannel)
```

**Bridge ownership model:**

```dart
// External bridge (caller manages lifecycle):
final bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);
await bridge.initialize();
UnityView(bridge: bridge, ...); // Widget never disposes this bridge

// Internal bridge (widget manages lifecycle):
UnityView(bridge: null, ...); // Widget creates and disposes its own bridge
```

This solves the biggest pain point from `flutter_unity_widget`: the controller being destroyed when the widget rebuilds or is removed from the tree.

---

## Lifecycle State Machine

The Unity player follows a strict state machine. Invalid transitions throw `LifecycleException`.

```
                                +----------+
                                | disposed |
                                +----------+
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
| `disposed` | *(terminal -- cannot reuse)* |

---

## Communication Protocol

### Flutter -> Unity

Messages are sent via `UnitySendMessage` targeting a specific GameObject and method:

```
JSON: {"target":"ModelObject", "method":"Rotate", "data":"45"}
      |                       |                  |
      FlutterMessage.target   FlutterMessage.method  FlutterMessage.data
```

The `FlutterBridge` C# singleton receives the message at `ReceiveMessage(json)`, deserializes it, and routes it via `MessageRouter` to the registered handler matching `target`.

### Unity -> Flutter

Messages from Unity use two formats:

**Typed messages** (general events):
```json
{"type":"score_updated", "data":{"score":100}}
```

**Routed messages** (targeting specific handlers):
```json
{"target":"GameManager", "method":"OnResult", "data":"win"}
```

Both arrive on the Dart side via `bridge.messageStream`.

### Scene notifications

Scene load/unload events are sent via a dedicated native call (`NativeAPI.NotifySceneLoaded`) and arrive on `bridge.sceneStream` as `SceneInfo` objects.

---

## Platform Layer

### Android

```
Kotlin Code
+-- UnityKitPlugin          (FlutterPlugin entry point)
+-- UnityKitViewFactory      (PlatformViewFactory for AndroidView)
+-- UnityKitViewController   (PlatformView + MethodChannel handler)
+-- UnityPlayerManager       (Singleton Unity player lifecycle)
+-- FlutterBridgeRegistry    (Routes Unity messages to Flutter controllers)
```

### iOS

```
Swift Plugin Code (unity_kit/ios/Classes/)
+-- SwiftUnityKitPlugin       (FlutterPlugin entry point, view factory registration)
+-- UnityKitViewFactory       (FlutterPlatformViewFactory)
+-- UnityKitViewController    (FlutterPlatformView + MethodChannel handler)
+-- UnityKitView              (UIView container for Unity view)
+-- UnityPlayerManager        (Singleton Unity player lifecycle)
+-- FlutterBridgeRegistry     (Routes Unity messages to Flutter controllers)
+-- UnityEventListener        (Protocol for Unity event callbacks)

Native Bridge (compiled into UnityFramework, not in Flutter plugin)
+-- UnityKitNativeBridge.mm   (extern "C" symbols for IL2CPP DllImport)
```

**Native bridge pattern:** C# `[DllImport("__Internal")]` resolves to `extern "C"` symbols in `UnityKitNativeBridge.mm`, which is compiled into `UnityFramework.framework`. At runtime, it forwards to `FlutterBridgeRegistry` via ObjC runtime (`NSClassFromString` + `performSelector`). This indirection is necessary because the Flutter plugin and UnityFramework are separate binaries.

**Auto-initialization:** `UnityKitViewController` mirrors Android's auto-init pattern: `init()` → `waitForNonZeroFrame()` → `autoInitialize()` → `waitForUnityView()`. The non-zero frame guard prevents Metal texture crashes (`MTLTextureDescriptor has width of zero`).

### MethodChannel naming

Each platform view gets its own MethodChannel:
```
com.unity_kit/unity_view_{viewId}
```

Events use a shared EventChannel:
```
com.unity_kit/unity_events
```

---

## Asset Streaming Pipeline

```
StreamingController
+-- ContentDownloader       (HTTP downloads with retries, progress, cancellation)
|   +-- CacheManager        (local file cache with SHA-256 integrity)
+-- UnityBridge             (tells Unity to load from local cache)

Flow:
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

The manifest format:
```json
{
  "version": "1.0.0",
  "baseUrl": "https://cdn.example.com/bundles",
  "catalogUrl": "https://cdn.example.com/bundles/catalog_2024.bin",
  "bundles": [
    {"name": "core", "url": "...", "sizeBytes": 5242880, "sha256": "...", "isBase": true},
    {"name": "toys_assets_alphie_abc123.bundle", "url": "...", "sizeBytes": 10485760, "dependencies": ["core"], "group": "addressables", "metadata": {"addressableKeys": ["alphie"]}}
  ]
}
```

### Addressable Key Extraction

When loading a remote asset, `StreamingController.extractAddressableKey()` determines the Addressable address from a bundle entry:

1. **Metadata lookup** — If `bundle.metadata['addressableKeys']` exists (generated by `AddressablesManifestBuilder`), use the first key. This is the most reliable method.
2. **Regex extraction** — Strip the `.bundle` extension, remove the 32-character hex content hash suffix, then remove the group prefix (e.g. `toys_assets_`). This is a heuristic fallback.
3. **Raw name** — If neither method produces a result, use the cleaned bundle name as-is.

The `AddressablesManifestBuilder` (Unity Editor tool) generates `metadata.addressableKeys` by matching Addressable group entries to built bundle filenames.

### UnityKitLogger (C# logging)

All UnityKit C# scripts use `UnityKitLogger` — a static class with delegate-based log routing. By default it writes to `Debug.Log` with a `[UnityKit]` prefix. Projects wire their own logger at startup:

```csharp
// In project bootstrap (e.g. CryptoysLogger.cs):
UnityKitLogger.LogAction = msg => CryptoysLogger.Info(LogCategory.Bridge, msg);
UnityKitLogger.WarnAction = msg => CryptoysLogger.Warning(LogCategory.Bridge, msg);
UnityKitLogger.ErrorAction = msg => CryptoysLogger.Error(LogCategory.Bridge, msg);
```

This decouples UnityKit scripts from project-specific logging, allowing them to be synced from `unity_kit` without modification.

---

## Exception Hierarchy

```
UnityKitException (base)
+-- BridgeException              (bridge communication failures)
+-- CommunicationException       (message delivery failures, includes target/method context)
+-- EngineNotReadyException      (sending before Unity is ready)
+-- LifecycleException           (invalid state transitions, includes current state)
```

All exceptions carry `message`, optional `cause`, and optional `stackTrace`.

---

## Design Decisions

### 1. Bridge independent of widget

**Problem:** In `flutter_unity_widget`, the controller is tied to the widget. Navigating away destroys the controller, losing the ability to communicate with Unity.

**Solution:** The bridge is a standalone object. It can be created in a service layer, injected into widgets, and survives widget disposal. `UnityView` accepts an optional external bridge; if provided, it never disposes it.

### 2. Readiness guard with message queuing

**Problem:** Messages sent before Unity is initialized are silently dropped.

**Solution:** `ReadinessGuard` provides two modes: `guard()` throws immediately, `queueUntilReady()` queues messages and auto-flushes when the engine reports ready.

### 3. Typed messages instead of raw strings

**Problem:** `flutter_unity_widget` uses raw strings for communication. No structure, no type safety.

**Solution:** `UnityMessage` with `type`, `data`, `gameObject`, `method` fields and factory constructors (`command`, `to`, `fromJson`).

### 4. Stream-based event system

**Problem:** Callback-based event systems create coupling and make cleanup error-prone.

**Solution:** Four typed streams (`messageStream`, `eventStream`, `sceneStream`, `lifecycleStream`) with automatic cleanup on dispose.

### 5. Reflection-based Unity player creation

**Problem:** Unity 6 changed the player class name and constructor signatures. Direct compilation dependency breaks across Unity versions.

**Solution:** The Android native layer uses reflection to try `UnityPlayerForActivityOrService` (Unity 6) first, then falls back to `UnityPlayer` (legacy). Multiple constructor signatures are attempted.

### 6. Message batching and throttling

**Problem:** Rapid message sending (e.g., position updates every frame) floods the native bridge and causes frame drops.

**Solution:** Optional `MessageBatcher` (coalesces by key, flushes per frame) and `MessageThrottler` (rate-limits with configurable strategy: drop, keepLatest, keepFirst).

---

## Comparison with Alternatives

### vs flutter_unity_widget

| Aspect | flutter_unity_widget | unity_kit |
|--------|---------------------|-----------|
| Controller lifetime | Tied to widget | Independent bridge |
| Message types | Raw strings | Typed `UnityMessage` |
| Lifecycle management | None | State machine with guards |
| Readiness guard | None | Queue + auto-flush |
| Message batching | None | Batcher + Throttler |
| Asset streaming | None | Full pipeline with caching |
| Exception handling | Swallowed errors | Typed exception hierarchy |
| Unity 6 support | Not supported | Reflection with fallback |
| Tests | 2 files | 28+ test files |

### vs gameframework

| Aspect | gameframework | unity_kit |
|--------|---------------|-----------|
| Engine support | Unity + Unreal | Unity only |
| Architecture | Monorepo, multi-package | Single package |
| Maturity | Very new (v0.0.2) | New but focused |
| Cloud services | GameFramework Cloud | Standard CDN |
| Patterns adopted | Factory+Registry, typed everything | Same patterns, single-engine focus |

### Patterns adopted from gameframework

- Abstract bridge interface
- Typed messages and events with timestamps
- Scene tracking via dedicated stream
- Exception hierarchy (renamed from `GameEngineException` tree)
- Config object with `copyWith`
- Message batching (C# and Dart)
- Platform view mode enum

### Anti-patterns avoided from flutter_unity_widget

- Controller tied to widget lifecycle
- Raw string messages without structure
- Swallowed errors (`catch(e) { /* todo */ }`)
- Lack of resource cleanup
- Lack of readiness checking before sends
- Lack of message rate limiting

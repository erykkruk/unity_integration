import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../bridge/unity_bridge.dart';
import '../models/models.dart';
import '../platform/unity_kit_platform.dart';
import '../utils/logger.dart';

/// Platform view type identifier registered with native embedders.
const String _viewType = 'com.unity_kit/unity_view';

/// A Flutter widget that embeds a Unity 3D view with typed communication.
///
/// [UnityView] wraps the native Unity player as a platform view and exposes
/// stream-based callbacks for messages, events, scene loads, and readiness.
///
/// The [bridge] parameter is optional. When omitted, the widget creates an
/// internal [UnityBridgeImpl] and owns its lifecycle. When provided, the
/// caller owns the bridge -- the widget will **never** dispose an external
/// bridge (Issue #1: bridge survives widget).
///
/// Example:
/// ```dart
/// UnityView(
///   config: const UnityConfig(sceneName: 'GameScene'),
///   placeholder: const Center(child: CircularProgressIndicator()),
///   onReady: (bridge) {
///     bridge.send(UnityMessage.command('StartGame'));
///   },
///   onMessage: (message) {
///     if (message.type == 'score_updated') {
///       // handle score
///     }
///   },
/// )
/// ```
class UnityView extends StatefulWidget {
  /// Creates a new [UnityView].
  const UnityView({
    super.key,
    this.bridge,
    this.config = const UnityConfig(),
    this.placeholder,
    this.onReady,
    this.onMessage,
    this.onEvent,
    this.onSceneLoaded,
    this.gestureRecognizers,
  });

  /// External bridge instance. Bridge is INDEPENDENT of widget (Issue #1).
  ///
  /// If null, creates one internally using [UnityKitPlatform.instance].
  final UnityBridge? bridge;

  /// Unity configuration controlling fullscreen, status bar, and view mode.
  final UnityConfig config;

  /// Widget to display while Unity is loading.
  ///
  /// Shown as an overlay on top of the platform view until the bridge
  /// emits [UnityLifecycleState.ready].
  final Widget? placeholder;

  /// Called once when the Unity player is ready to receive messages.
  final void Function(UnityBridge bridge)? onReady;

  /// Called for every message received from Unity.
  final void Function(UnityMessage message)? onMessage;

  /// Called for every lifecycle event emitted by the Unity player.
  final void Function(UnityEvent event)? onEvent;

  /// Called when a Unity scene finishes loading.
  final void Function(SceneInfo scene)? onSceneLoaded;

  /// Gesture recognizers for the platform view.
  ///
  /// When provided, these are passed through to the underlying [AndroidView]
  /// or [UiKitView] so that the host app can intercept touch events before
  /// they reach the Unity player.
  ///
  /// When null, an empty set is used (default platform view behaviour).
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  @override
  State<UnityView> createState() => _UnityViewState();
}

class _UnityViewState extends State<UnityView> {
  late final UnityBridge _bridge;
  late final bool _ownsBridge;
  bool _unityReady = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();

    if (widget.bridge != null) {
      _bridge = widget.bridge!;
      _ownsBridge = false;
    } else {
      _bridge = UnityBridgeImpl(platform: UnityKitPlatform.instance);
      _ownsBridge = true;
    }

    _subscribeToStreams();

    if (_ownsBridge) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _bridge.initialize();
      });
    }
  }

  void _subscribeToStreams() {
    _subscriptions.add(
      _bridge.messageStream.listen((message) {
        widget.onMessage?.call(message);
      }),
    );

    _subscriptions.add(
      _bridge.eventStream.listen((event) {
        widget.onEvent?.call(event);
      }),
    );

    _subscriptions.add(
      _bridge.sceneStream.listen((scene) {
        widget.onSceneLoaded?.call(scene);
      }),
    );

    _subscriptions.add(
      _bridge.lifecycleStream.listen((state) {
        if (state == UnityLifecycleState.ready && !_unityReady) {
          setState(() => _unityReady = true);
          widget.onReady?.call(_bridge);
          UnityKitLogger.instance.info('UnityView: bridge is ready');
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildPlatformView(),
        if (!_unityReady && widget.placeholder != null) widget.placeholder!,
      ],
    );
  }

  Widget _buildPlatformView() {
    final creationParams = <String, dynamic>{
      'fullscreen': widget.config.fullscreen,
      'hideStatusBar': widget.config.hideStatusBar,
      'runImmediately': widget.config.runImmediately,
      'platformViewMode': widget.config.platformViewMode.name,
      'targetFrameRate': widget.config.targetFrameRate,
    };

    final gestureRecognizers = widget.gestureRecognizers ??
        const <Factory<OneSequenceGestureRecognizer>>{};

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // Hybrid Composition ensures Unity's SurfaceView renders within
        // its Flutter widget bounds instead of covering the entire screen.
        // Virtual Display (default AndroidView) causes z-order issues
        // where Unity floats on top of all Flutter content (Issue #1).
        return PlatformViewLink(
          viewType: _viewType,
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
              viewType: _viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
            )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
          },
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: widget.gestureRecognizers ??
              const <Factory<OneSequenceGestureRecognizer>>{},
        );
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return const Center(child: Text('Platform not supported'));
    }
  }

  // App lifecycle (pause/resume) is handled exclusively by native:
  // - Android: DefaultLifecycleObserver in UnityKitViewController
  // - iOS: NotificationCenter observers in UnityPlayerManager
  // Dart-side handling was removed to prevent double pause/resume cycles
  // that caused Unity to hang (redundant MethodChannel round-trips).

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();

    // Only dispose the bridge if this widget created it internally.
    // External bridges survive widget disposal (Issue #1).
    if (_ownsBridge) {
      _bridge.dispose();
    }

    super.dispose();
  }
}

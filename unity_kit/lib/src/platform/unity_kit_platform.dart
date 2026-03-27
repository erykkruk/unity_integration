import 'dart:async';

import 'unity_kit_method_channel.dart';

/// Abstract platform interface for Unity player operations.
///
/// Defines the contract between Dart code and native platform.
/// The default implementation uses MethodChannel.
abstract class UnityKitPlatform {
  /// Singleton instance (replaceable for testing).
  static UnityKitPlatform instance = UnityKitMethodChannel();

  /// Pre-initialize Unity player before widget mount.
  Future<void> initialize({bool earlyInit = false});

  /// Check if Unity player is ready.
  Future<bool> isReady();

  /// Check if Unity player is loaded.
  Future<bool> isLoaded();

  /// Check if Unity player is paused.
  Future<bool> isPaused();

  /// Send message to Unity GameObject.
  Future<void> postMessage(
    String gameObject,
    String methodName,
    String message,
  );

  /// Pause Unity player.
  Future<void> pause();

  /// Resume Unity player.
  Future<void> resume();

  /// Unload Unity player (keeps process alive).
  Future<void> unload();

  /// Quit Unity player completely.
  Future<void> quit();

  /// Dispose resources for a specific view.
  Future<void> dispose(int viewId);

  /// Create Unity player for a specific view.
  Future<void> createUnityPlayer(int viewId, Map<String, dynamic> config);

  /// Bind a MethodChannel for [viewId] and set it as the active channel
  /// for all subsequent platform calls.
  void registerViewChannel(int viewId);

  /// Stream of raw events from native side.
  Stream<Map<String, dynamic>> get events;

  /// Get the platform view type identifier.
  String get viewType;
}

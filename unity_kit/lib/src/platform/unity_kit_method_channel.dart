import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/constants.dart';
import '../utils/logger.dart';
import 'unity_kit_platform.dart';

/// MethodChannel implementation of [UnityKitPlatform].
class UnityKitMethodChannel extends UnityKitPlatform {
  final Map<int, MethodChannel> _channels = {};
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();
  bool _isDisposed = false;
  int _activeViewId = 0;

  MethodChannel _channelForView(int viewId) {
    return _channels.putIfAbsent(viewId, () {
      final channel = MethodChannel(ChannelNames.methodChannel(viewId));
      channel.setMethodCallHandler((call) => _handlePlatformCall(call, viewId));
      return channel;
    });
  }

  Future<Object?> _handlePlatformCall(MethodCall call, int viewId) async {
    if (_isDisposed) return null;

    final event = <String, Object?>{
      'event': call.method,
      'viewId': viewId,
    };

    if (call.arguments != null) {
      if (call.arguments is Map) {
        event.addAll(Map<String, dynamic>.from(call.arguments as Map));
      } else {
        event['data'] = call.arguments;
      }
    }

    _eventController.add(Map<String, dynamic>.from(event));
    return null;
  }

  @override
  Future<void> initialize({bool earlyInit = false}) async {
    // Just ensure the channel exists so we can receive events.
    // The native side auto-initializes Unity when the PlatformView is created,
    // so we don't need to send a MethodChannel call here.
    _channelForView(_activeViewId);
  }

  @override
  Future<bool> isReady() async {
    final channel = _channelForView(_activeViewId);
    try {
      final result = await channel.invokeMethod<bool>('unity#isReady');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> isLoaded() async {
    final channel = _channelForView(_activeViewId);
    try {
      final result = await channel.invokeMethod<bool>('unity#isLoaded');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> isPaused() async {
    final channel = _channelForView(_activeViewId);
    try {
      final result = await channel.invokeMethod<bool>('unity#isPaused');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> postMessage(
    String gameObject,
    String methodName,
    String message,
  ) async {
    final channel = _channelForView(_activeViewId);
    try {
      await channel.invokeMethod<void>('unity#postMessage', {
        'gameObject': gameObject,
        'methodName': methodName,
        'message': message,
      });
    } on PlatformException catch (e) {
      UnityKitLogger.instance.error('Failed to post message to Unity', e);
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    final channel = _channelForView(_activeViewId);
    await channel.invokeMethod<void>('unity#pausePlayer');
  }

  @override
  Future<void> resume() async {
    final channel = _channelForView(_activeViewId);
    await channel.invokeMethod<void>('unity#resumePlayer');
  }

  @override
  Future<void> unload() async {
    final channel = _channelForView(_activeViewId);
    await channel.invokeMethod<void>('unity#unloadPlayer');
  }

  @override
  Future<void> quit() async {
    final channel = _channelForView(_activeViewId);
    await channel.invokeMethod<void>('unity#quitPlayer');
  }

  @override
  Future<void> dispose(int viewId) async {
    final channel = _channels.remove(viewId);
    if (channel != null) {
      try {
        await channel.invokeMethod<void>('unity#dispose');
      } catch (_) {
        // Ignore errors during dispose
      }
      channel.setMethodCallHandler(null);
    }
    if (_channels.isEmpty) {
      _isDisposed = true;
      await _eventController.close();
    }
  }

  @override
  Future<void> createUnityPlayer(
    int viewId,
    Map<String, dynamic> config,
  ) async {
    final channel = _channelForView(viewId);
    await channel.invokeMethod<void>('unity#createPlayer', config);
  }

  @override
  void registerViewChannel(int viewId) {
    _channelForView(viewId);
    _activeViewId = viewId;
  }

  @override
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  @override
  String get viewType => 'com.unity_kit/unity_view';
}

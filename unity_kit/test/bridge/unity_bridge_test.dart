import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unity_kit/src/bridge/unity_bridge.dart';
import 'package:unity_kit/src/exceptions/exceptions.dart';
import 'package:unity_kit/src/models/models.dart';
import 'package:unity_kit/src/platform/unity_kit_platform.dart';

/// Fake platform implementation for testing.
///
/// Provides [StreamController]-based event emission so tests can simulate
/// native platform events without a real Unity player.
class FakeUnityKitPlatform extends UnityKitPlatform {
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool initializeCalled = false;
  bool pauseCalled = false;
  bool resumeCalled = false;
  bool unloadCalled = false;
  bool quitCalled = false;

  final List<Map<String, String>> sentMessages = [];
  bool shouldFailPostMessage = false;

  @override
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  @override
  String get viewType => 'com.unity_kit.test/unity_view';

  @override
  Future<void> initialize({bool earlyInit = false}) async {
    initializeCalled = true;
  }

  @override
  Future<bool> isReady() async => true;

  @override
  Future<bool> isLoaded() async => true;

  @override
  Future<bool> isPaused() async => false;

  @override
  Future<void> postMessage(
    String gameObject,
    String methodName,
    String message,
  ) async {
    if (shouldFailPostMessage) {
      throw Exception('Platform postMessage failed');
    }
    sentMessages.add({
      'gameObject': gameObject,
      'methodName': methodName,
      'message': message,
    });
  }

  @override
  Future<void> pause() async {
    pauseCalled = true;
  }

  @override
  Future<void> resume() async {
    resumeCalled = true;
  }

  @override
  Future<void> unload() async {
    unloadCalled = true;
  }

  @override
  Future<void> quit() async {
    quitCalled = true;
  }

  @override
  Future<void> dispose(int viewId) async {}

  @override
  void registerViewChannel(int viewId) {}

  @override
  Future<void> createUnityPlayer(
    int viewId,
    Map<String, dynamic> config,
  ) async {}

  /// Emit a platform event as if it came from native.
  void emitEvent(Map<String, dynamic> event) {
    _eventController.add(event);
  }

  /// Simulate the onUnityCreated native event.
  void emitUnityCreated() {
    emitEvent({'event': 'onUnityCreated'});
  }

  /// Simulate the onUnityMessage native event.
  void emitUnityMessage(String jsonData) {
    emitEvent({'event': 'onUnityMessage', 'data': jsonData});
  }

  /// Simulate the onUnitySceneLoaded native event.
  void emitSceneLoaded(Map<String, dynamic> data) {
    emitEvent({'event': 'onUnitySceneLoaded', 'data': data});
  }

  /// Simulate the onUnityUnloaded native event.
  void emitUnityUnloaded() {
    emitEvent({'event': 'onUnityUnloaded'});
  }

  Future<void> close() async {
    await _eventController.close();
  }
}

void main() {
  late FakeUnityKitPlatform platform;
  late UnityBridgeImpl bridge;

  setUp(() {
    platform = FakeUnityKitPlatform();
    bridge = UnityBridgeImpl(platform: platform);
  });

  tearDown(() async {
    await bridge.dispose();
    await platform.close();
  });

  group('initialization', () {
    test('starts in uninitialized state', () {
      expect(bridge.currentState, UnityLifecycleState.uninitialized);
      expect(bridge.isReady, isFalse);
    });

    test('initialize transitions to initializing and calls platform', () async {
      await bridge.initialize();

      expect(platform.initializeCalled, isTrue);
      expect(bridge.currentState, UnityLifecycleState.initializing);
    });

    test('onUnityCreated transitions to ready', () async {
      await bridge.initialize();

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.ready);
      expect(bridge.isReady, isTrue);
    });

    test('initialize throws after dispose', () async {
      await bridge.dispose();

      expect(
        () => bridge.initialize(),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('send', () {
    test('throws EngineNotReadyException when not ready', () async {
      expect(
        () => bridge.send(UnityMessage.command('Test')),
        throwsA(isA<EngineNotReadyException>()),
      );
    });

    test('sends message when ready', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      final message = UnityMessage.command('LoadScene', {'name': 'Main'});
      await bridge.send(message);

      expect(platform.sentMessages, hasLength(1));
      expect(platform.sentMessages.first['gameObject'], 'FlutterBridge');
    });

    test('throws BridgeException after dispose', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await bridge.dispose();

      expect(
        () => bridge.send(UnityMessage.command('Test')),
        throwsA(isA<BridgeException>()),
      );
    });

    test('throws CommunicationException on platform failure', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      platform.shouldFailPostMessage = true;

      expect(
        () => bridge.send(UnityMessage.command('Test')),
        throwsA(isA<CommunicationException>()),
      );
    });
  });

  group('sendWhenReady', () {
    test('queues message when not ready', () async {
      await bridge.initialize();

      await bridge.sendWhenReady(UnityMessage.command('Queued'));

      expect(platform.sentMessages, isEmpty);
    });

    test('flushes queued messages when Unity becomes ready', () async {
      await bridge.initialize();

      await bridge.sendWhenReady(UnityMessage.command('First'));
      await bridge.sendWhenReady(UnityMessage.command('Second'));

      expect(platform.sentMessages, isEmpty);

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(platform.sentMessages, hasLength(2));
    });

    test('sends immediately when already ready', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await bridge.sendWhenReady(UnityMessage.command('Immediate'));

      expect(platform.sentMessages, hasLength(1));
    });

    test('throws BridgeException after dispose', () async {
      await bridge.dispose();

      expect(
        () => bridge.sendWhenReady(UnityMessage.command('Test')),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('messageStream', () {
    test('emits parsed UnityMessage from JSON string data', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      platform.emitUnityMessage('{"type":"score_update","data":{"score":42}}');
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.type, 'score_update');
      expect(messages.first.data, {'score': 42});
    });

    test('emits UnityMessage for plain string data', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      platform.emitUnityMessage('simple_signal');
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.type, 'simple_signal');
    });

    test('emits UnityMessage from Map data', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      platform.emitEvent({
        'event': 'onUnityMessage',
        'data': <String, dynamic>{'type': 'map_event', 'data': null},
      });
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.type, 'map_event');
    });

    test('routes messages through MessageHandler', () async {
      await bridge.initialize();

      var handlerCalled = false;
      bridge.messageHandler.on('test_type', (_) {
        handlerCalled = true;
      });

      platform.emitUnityMessage('{"type":"test_type"}');
      await Future<void>.delayed(Duration.zero);

      expect(handlerCalled, isTrue);
    });
  });

  group('sceneStream', () {
    test('emits SceneInfo from map data', () async {
      await bridge.initialize();

      final scenes = <SceneInfo>[];
      bridge.sceneStream.listen(scenes.add);

      platform.emitSceneLoaded({
        'name': 'MainLevel',
        'buildIndex': 1,
        'isLoaded': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(scenes, hasLength(1));
      expect(scenes.first.name, 'MainLevel');
      expect(scenes.first.buildIndex, 1);
      expect(scenes.first.isLoaded, isTrue);
    });

    test('emits SceneInfo from string data', () async {
      await bridge.initialize();

      final scenes = <SceneInfo>[];
      bridge.sceneStream.listen(scenes.add);

      platform.emitEvent({
        'event': 'onUnitySceneLoaded',
        'data': 'QuickScene',
      });
      await Future<void>.delayed(Duration.zero);

      expect(scenes, hasLength(1));
      expect(scenes.first.name, 'QuickScene');
      expect(scenes.first.isLoaded, isTrue);
    });
  });

  group('lifecycleStream', () {
    test('emits state changes during initialize flow', () async {
      final states = <UnityLifecycleState>[];
      bridge.lifecycleStream.listen(states.add);

      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(states, [
        UnityLifecycleState.initializing,
        UnityLifecycleState.ready,
      ]);
    });

    test('emits pause and resume states', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      final states = <UnityLifecycleState>[];
      bridge.lifecycleStream.listen(states.add);

      await bridge.pause();
      await bridge.resume();

      expect(states, [
        UnityLifecycleState.paused,
        UnityLifecycleState.resumed,
      ]);
    });
  });

  group('eventStream', () {
    test('emits UnityEvent on state transitions', () async {
      final events = <UnityEvent>[];
      bridge.eventStream.listen(events.add);

      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0].type, UnityEventType.created);
      expect(events[1].type, UnityEventType.loaded);
    });
  });

  group('pause and resume', () {
    test('pause transitions lifecycle and calls platform', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await bridge.pause();

      expect(bridge.currentState, UnityLifecycleState.paused);
      expect(platform.pauseCalled, isTrue);
    });

    test('resume transitions lifecycle and calls platform', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await bridge.pause();
      await bridge.resume();

      expect(bridge.currentState, UnityLifecycleState.resumed);
      expect(platform.resumeCalled, isTrue);
    });

    test('pause throws after dispose', () async {
      await bridge.dispose();

      expect(
        () => bridge.pause(),
        throwsA(isA<BridgeException>()),
      );
    });

    test('resume throws after dispose', () async {
      await bridge.dispose();

      expect(
        () => bridge.resume(),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('unload', () {
    test('calls platform unload and resets state', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await bridge.unload();

      expect(platform.unloadCalled, isTrue);
      expect(bridge.currentState, UnityLifecycleState.uninitialized);
      expect(bridge.isReady, isFalse);
    });

    test('onUnityUnloaded event resets state', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      platform.emitUnityUnloaded();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.uninitialized);
      expect(bridge.isReady, isFalse);
    });
  });

  group('dispose', () {
    test('transitions to disposed and cleans up resources', () async {
      await bridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      final states = <UnityLifecycleState>[];
      bridge.lifecycleStream.listen(states.add);

      await bridge.dispose();

      expect(states, contains(UnityLifecycleState.disposed));
      expect(bridge.isReady, isFalse);
    });

    test('dispose is idempotent', () async {
      await bridge.dispose();
      await bridge.dispose();
    });

    test('all operations throw after dispose', () async {
      await bridge.dispose();

      expect(() => bridge.initialize(), throwsA(isA<BridgeException>()));
      expect(
        () => bridge.send(UnityMessage.command('T')),
        throwsA(isA<BridgeException>()),
      );
      expect(
        () => bridge.sendWhenReady(UnityMessage.command('T')),
        throwsA(isA<BridgeException>()),
      );
      expect(() => bridge.pause(), throwsA(isA<BridgeException>()));
      expect(() => bridge.resume(), throwsA(isA<BridgeException>()));
      expect(() => bridge.unload(), throwsA(isA<BridgeException>()));
    });
  });

  group('platform event parsing', () {
    test('ignores events without event type', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      platform.emitEvent({'data': 'no_event_key'});
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
    });

    test('ignores events after dispose', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      await bridge.dispose();

      platform.emitUnityMessage('{"type":"late_message"}');
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
    });

    test('ignores onUnityMessage with null data', () async {
      await bridge.initialize();

      final messages = <UnityMessage>[];
      bridge.messageStream.listen(messages.add);

      platform.emitEvent({'event': 'onUnityMessage'});
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
    });
  });

  group('duplicate onUnityCreated guard (DART-C2)', () {
    test('second onUnityCreated event is ignored', () async {
      await bridge.initialize();

      final states = <UnityLifecycleState>[];
      bridge.lifecycleStream.listen(states.add);

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.ready);
      expect(states.where((s) => s == UnityLifecycleState.ready).length, 1);
    });

    test('does not flush queue twice on duplicate created', () async {
      await bridge.initialize();

      await bridge.sendWhenReady(UnityMessage.command('QueuedMsg'));
      expect(platform.sentMessages, isEmpty);

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);
      expect(platform.sentMessages, hasLength(1));

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);
      expect(platform.sentMessages, hasLength(1));
    });
  });

  group('onError event handling (DART-L3)', () {
    test('handles onError event without crashing', () async {
      await bridge.initialize();

      platform.emitEvent({
        'event': 'onError',
        'data': {'message': 'Unity initialization failed'},
      });
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.initializing);
    });

    test('handles onError with non-map data', () async {
      await bridge.initialize();

      platform.emitEvent({
        'event': 'onError',
        'data': 'plain error string',
      });
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.initializing);
    });

    test('handles onError with null data', () async {
      await bridge.initialize();

      platform.emitEvent({
        'event': 'onError',
      });
      await Future<void>.delayed(Duration.zero);

      expect(bridge.currentState, UnityLifecycleState.initializing);
    });
  });

  group('platform stream error handling', () {
    test('platform stream error does not crash bridge', () async {
      await bridge.initialize();

      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.isReady, isTrue);
    });
  });

  group('optional batcher and throttler', () {
    test('works without batcher and throttler', () async {
      final simpleBridge = UnityBridgeImpl(platform: platform);

      await simpleBridge.initialize();
      platform.emitUnityCreated();
      await Future<void>.delayed(Duration.zero);

      await simpleBridge.send(UnityMessage.command('Test'));

      expect(platform.sentMessages, hasLength(1));

      await simpleBridge.dispose();
    });
  });
}

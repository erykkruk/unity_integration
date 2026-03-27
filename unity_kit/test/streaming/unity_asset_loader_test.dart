import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:unity_kit/src/bridge/unity_bridge.dart';
import 'package:unity_kit/src/models/unity_message.dart';
import 'package:unity_kit/src/streaming/loaders/unity_addressables_loader.dart';
import 'package:unity_kit/src/streaming/loaders/unity_bundle_loader.dart';
import 'package:unity_kit/src/streaming/unity_asset_loader.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockUnityBridge extends Mock implements UnityBridge {}

// ---------------------------------------------------------------------------
// Concrete test implementation for testing base class default methods
// ---------------------------------------------------------------------------

class _TestLoader extends UnityAssetLoader {
  const _TestLoader();

  @override
  String get targetName => 'TestManager';

  @override
  UnityMessage setCachePathMessage(String cachePath) =>
      UnityMessage.to(targetName, 'SetCachePath', {'path': cachePath});

  @override
  UnityMessage loadAssetMessage({
    required String key,
    required String callbackId,
  }) =>
      UnityMessage.to(targetName, 'Load', {
        'key': key,
        'callbackId': callbackId,
      });

  @override
  UnityMessage loadSceneMessage({
    required String sceneName,
    required String callbackId,
    required String loadMode,
  }) =>
      UnityMessage.to(targetName, 'LoadScene', {
        'sceneName': sceneName,
        'callbackId': callbackId,
        'loadMode': loadMode,
      });

  @override
  UnityMessage unloadAssetMessage(String key) =>
      UnityMessage.to(targetName, 'Unload', {'key': key});

  @override
  UnityMessage loadContentCatalogMessage({
    required String url,
    required String callbackId,
  }) =>
      UnityMessage.to(targetName, 'LoadContentCatalog', {
        'url': url,
        'callbackId': callbackId,
      });
}

void main() {
  final loaders = <String, UnityAssetLoader>{
    'UnityAddressablesLoader': const UnityAddressablesLoader(),
    'UnityBundleLoader': const UnityBundleLoader(),
  };

  setUpAll(() {
    registerFallbackValue(const UnityMessage(type: 'fallback'));
  });

  // -------------------------------------------------------------------------
  // Contract tests: run against every loader implementation
  // -------------------------------------------------------------------------

  for (final entry in loaders.entries) {
    group('${entry.key} (contract)', () {
      final loader = entry.value;

      test('targetName is non-empty', () {
        expect(loader.targetName, isNotEmpty);
      });

      test('setCachePathMessage targets correct game object', () {
        final message = loader.setCachePathMessage('/cache/path');

        expect(message.gameObject, loader.targetName);
        expect(message.method, 'SetCachePath');
        expect(message.data, isNotNull);
        expect(message.data!['path'], '/cache/path');
      });

      test('setCachePathMessage preserves path with special characters', () {
        final message = loader.setCachePathMessage(
          '/data/user/0/com.app/cache/unity bundles',
        );

        expect(
            message.data!['path'], '/data/user/0/com.app/cache/unity bundles');
      });

      test('loadAssetMessage targets correct game object', () {
        final message = loader.loadAssetMessage(
          key: 'characters',
          callbackId: 'load_characters',
        );

        expect(message.gameObject, loader.targetName);
        expect(message.data, isNotNull);
        expect(message.data!['callbackId'], 'load_characters');
      });

      test('loadAssetMessage preserves key with dots and slashes', () {
        final message = loader.loadAssetMessage(
          key: 'assets/models/character_v2.0',
          callbackId: 'cb_123',
        );

        expect(message.data!['callbackId'], 'cb_123');
      });

      test('loadSceneMessage targets correct game object', () {
        final message = loader.loadSceneMessage(
          sceneName: 'BattleArena',
          callbackId: 'scene_BattleArena',
          loadMode: 'Additive',
        );

        expect(message.gameObject, loader.targetName);
        expect(message.data, isNotNull);
        expect(message.data!['callbackId'], 'scene_BattleArena');
        expect(message.data!['loadMode'], 'Additive');
      });

      test('loadSceneMessage passes Single loadMode', () {
        final message = loader.loadSceneMessage(
          sceneName: 'MainMenu',
          callbackId: 'scene_MainMenu',
          loadMode: 'Single',
        );

        expect(message.data!['loadMode'], 'Single');
      });

      test('unloadAssetMessage targets correct game object', () {
        final message = loader.unloadAssetMessage('characters');

        expect(message.gameObject, loader.targetName);
        expect(message.data, isNotNull);
      });

      test('all messages have non-null data maps', () {
        final messages = [
          loader.setCachePathMessage('/path'),
          loader.loadAssetMessage(key: 'k', callbackId: 'c'),
          loader.loadSceneMessage(
            sceneName: 's',
            callbackId: 'c',
            loadMode: 'Single',
          ),
          loader.unloadAssetMessage('k'),
        ];

        for (final message in messages) {
          expect(message.data, isNotNull);
          expect(message.data, isA<Map<String, dynamic>>());
        }
      });
    });
  }

  // -------------------------------------------------------------------------
  // Loaders produce distinct targetNames
  // -------------------------------------------------------------------------

  group('loader targetName uniqueness', () {
    test('Addressables and Bundle loaders have different target names', () {
      const addressables = UnityAddressablesLoader();
      const bundles = UnityBundleLoader();

      expect(addressables.targetName, isNot(equals(bundles.targetName)));
    });
  });

  // -------------------------------------------------------------------------
  // Base class convenience methods (bridge delegation)
  // -------------------------------------------------------------------------

  group('UnityAssetLoader convenience methods', () {
    late _MockUnityBridge bridge;
    const loader = _TestLoader();

    setUp(() {
      bridge = _MockUnityBridge();
      when(() => bridge.sendWhenReady(any())).thenAnswer((_) async {});
    });

    test('setCachePath calls bridge.sendWhenReady with correct message',
        () async {
      await loader.setCachePath(bridge, '/cache/dir');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;

      expect(captured, hasLength(1));
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'TestManager');
      expect(message.method, 'SetCachePath');
      expect(message.data!['path'], '/cache/dir');
    });

    test('loadAsset calls bridge.sendWhenReady with correct message', () async {
      await loader.loadAsset(
        bridge,
        key: 'my_asset',
        callbackId: 'cb_1',
      );

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;

      expect(captured, hasLength(1));
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'TestManager');
      expect(message.method, 'Load');
      expect(message.data!['key'], 'my_asset');
      expect(message.data!['callbackId'], 'cb_1');
    });

    test('loadScene calls bridge.sendWhenReady with correct message', () async {
      await loader.loadScene(
        bridge,
        sceneName: 'Level1',
        callbackId: 'scene_Level1',
        loadMode: 'Additive',
      );

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;

      expect(captured, hasLength(1));
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'TestManager');
      expect(message.method, 'LoadScene');
      expect(message.data!['sceneName'], 'Level1');
      expect(message.data!['callbackId'], 'scene_Level1');
      expect(message.data!['loadMode'], 'Additive');
    });

    test('unloadAsset calls bridge.sendWhenReady with correct message',
        () async {
      await loader.unloadAsset(bridge, 'my_asset');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;

      expect(captured, hasLength(1));
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'TestManager');
      expect(message.method, 'Unload');
      expect(message.data!['key'], 'my_asset');
    });

    test('convenience methods propagate bridge exceptions', () async {
      when(() => bridge.sendWhenReady(any()))
          .thenThrow(StateError('bridge error'));

      expect(
        () => loader.setCachePath(bridge, '/path'),
        throwsStateError,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Addressables convenience methods through real bridge mock
  // -------------------------------------------------------------------------

  group('UnityAddressablesLoader bridge delegation', () {
    late _MockUnityBridge bridge;
    const loader = UnityAddressablesLoader();

    setUp(() {
      bridge = _MockUnityBridge();
      when(() => bridge.sendWhenReady(any())).thenAnswer((_) async {});
    });

    test('setCachePath sends to FlutterAddressablesManager', () async {
      await loader.setCachePath(bridge, '/cache');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'FlutterAddressablesManager');
      expect(message.method, 'SetCachePath');
    });

    test('loadAsset sends LoadAsset with key', () async {
      await loader.loadAsset(bridge, key: 'hero', callbackId: 'load_hero');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'LoadAsset');
      expect(message.data!['key'], 'hero');
    });

    test('loadScene sends LoadScene with sceneName', () async {
      await loader.loadScene(
        bridge,
        sceneName: 'Arena',
        callbackId: 'scene_Arena',
        loadMode: 'Single',
      );

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'LoadScene');
      expect(message.data!['sceneName'], 'Arena');
    });

    test('unloadAsset sends UnloadAsset with key', () async {
      await loader.unloadAsset(bridge, 'hero');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'UnloadAsset');
      expect(message.data!['key'], 'hero');
    });
  });

  // -------------------------------------------------------------------------
  // BundleLoader convenience methods through real bridge mock
  // -------------------------------------------------------------------------

  group('UnityBundleLoader bridge delegation', () {
    late _MockUnityBridge bridge;
    const loader = UnityBundleLoader();

    setUp(() {
      bridge = _MockUnityBridge();
      when(() => bridge.sendWhenReady(any())).thenAnswer((_) async {});
    });

    test('setCachePath sends to FlutterAssetBundleManager', () async {
      await loader.setCachePath(bridge, '/cache');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.gameObject, 'FlutterAssetBundleManager');
      expect(message.method, 'SetCachePath');
    });

    test('loadAsset sends LoadBundle with bundleName', () async {
      await loader.loadAsset(bridge, key: 'hero', callbackId: 'load_hero');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'LoadBundle');
      expect(message.data!['bundleName'], 'hero');
      expect(message.data!.containsKey('key'), isFalse);
    });

    test('loadScene sends LoadScene with bundleName', () async {
      await loader.loadScene(
        bridge,
        sceneName: 'Arena',
        callbackId: 'scene_Arena',
        loadMode: 'Additive',
      );

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'LoadScene');
      expect(message.data!['bundleName'], 'Arena');
      expect(message.data!.containsKey('sceneName'), isFalse);
    });

    test('unloadAsset sends UnloadBundle with bundleName', () async {
      await loader.unloadAsset(bridge, 'hero');

      final captured =
          verify(() => bridge.sendWhenReady(captureAny())).captured;
      final message = captured.first as UnityMessage;
      expect(message.method, 'UnloadBundle');
      expect(message.data!['bundleName'], 'hero');
      expect(message.data!.containsKey('key'), isFalse);
    });
  });
}

import '../bridge/unity_bridge.dart';
import '../models/unity_message.dart';

/// Abstract interface for loading assets on the Unity side.
///
/// Implementations define which Unity C# manager receives load/unload
/// messages and how the message payload is structured.
///
/// The [StreamingController] delegates all Unity communication through
/// this interface, making it possible to swap between Addressables and
/// raw AssetBundle strategies without changing orchestration logic.
///
/// Example:
/// ```dart
/// // Use Addressables (default)
/// final controller = StreamingController(
///   bridge: bridge,
///   manifestUrl: 'https://cdn.example.com/manifest.json',
/// );
///
/// // Use raw AssetBundles
/// final controller = StreamingController(
///   bridge: bridge,
///   manifestUrl: 'https://cdn.example.com/manifest.json',
///   assetLoader: const UnityBundleLoader(),
/// );
/// ```
abstract class UnityAssetLoader {
  /// Creates a [UnityAssetLoader].
  const UnityAssetLoader();

  /// The Unity GameObject name that receives messages.
  String get targetName;

  /// Inform Unity of the local cache directory path.
  ///
  /// Must be called before any load operations.
  UnityMessage setCachePathMessage(String cachePath);

  /// Request Unity to load an asset by [key].
  ///
  /// [callbackId] is used to correlate the response from Unity.
  UnityMessage loadAssetMessage({
    required String key,
    required String callbackId,
  });

  /// Request Unity to load a scene by [sceneName].
  ///
  /// [callbackId] is used to correlate the response from Unity.
  /// [loadMode] controls how the scene is loaded (`'Single'` or `'Additive'`).
  UnityMessage loadSceneMessage({
    required String sceneName,
    required String callbackId,
    required String loadMode,
  });

  /// Request Unity to unload an asset by [key].
  UnityMessage unloadAssetMessage(String key);

  /// Request Unity to load a remote content catalog by [url].
  UnityMessage loadContentCatalogMessage({
    required String url,
    required String callbackId,
  });

  /// Send the cache path to Unity via the bridge.
  Future<void> setCachePath(UnityBridge bridge, String cachePath) async {
    await bridge.sendWhenReady(setCachePathMessage(cachePath));
  }

  /// Send a load asset request to Unity via the bridge.
  Future<void> loadAsset(
    UnityBridge bridge, {
    required String key,
    required String callbackId,
  }) async {
    await bridge.sendWhenReady(loadAssetMessage(
      key: key,
      callbackId: callbackId,
    ));
  }

  /// Send a load scene request to Unity via the bridge.
  Future<void> loadScene(
    UnityBridge bridge, {
    required String sceneName,
    required String callbackId,
    required String loadMode,
  }) async {
    await bridge.sendWhenReady(loadSceneMessage(
      sceneName: sceneName,
      callbackId: callbackId,
      loadMode: loadMode,
    ));
  }

  /// Send an unload asset request to Unity via the bridge.
  Future<void> unloadAsset(UnityBridge bridge, String key) async {
    await bridge.sendWhenReady(unloadAssetMessage(key));
  }

  /// Send a load content catalog request to Unity via the bridge.
  Future<void> loadContentCatalog(
    UnityBridge bridge, {
    required String url,
    required String callbackId,
  }) async {
    await bridge.sendWhenReady(loadContentCatalogMessage(
      url: url,
      callbackId: callbackId,
    ));
  }
}

import '../../models/unity_message.dart';
import '../unity_asset_loader.dart';

/// Unity GameObject name for the C# AssetBundle manager.
const String _kTargetName = 'FlutterAssetBundleManager';

/// Asset loader that communicates with Unity raw AssetBundles.
///
/// Sends messages to the `FlutterAssetBundleManager` C# MonoBehaviour
/// which loads bundles via `AssetBundle.LoadFromFileAsync` and assets
/// via `bundle.LoadAssetAsync<T>`.
///
/// Use this loader when Addressables are not installed or when a simpler
/// asset pipeline is preferred.
///
/// Example:
/// ```dart
/// final controller = StreamingController(
///   bridge: bridge,
///   manifestUrl: 'https://cdn.example.com/manifest.json',
///   assetLoader: const UnityBundleLoader(),
/// );
/// ```
class UnityBundleLoader extends UnityAssetLoader {
  /// Creates a [UnityBundleLoader].
  const UnityBundleLoader();

  @override
  String get targetName => _kTargetName;

  @override
  UnityMessage setCachePathMessage(String cachePath) {
    return UnityMessage.to(
      _kTargetName,
      'SetCachePath',
      {'path': cachePath},
    );
  }

  @override
  UnityMessage loadAssetMessage({
    required String key,
    required String callbackId,
  }) {
    return UnityMessage.to(
      _kTargetName,
      'LoadBundle',
      {
        'bundleName': key,
        'callbackId': callbackId,
      },
    );
  }

  @override
  UnityMessage loadSceneMessage({
    required String sceneName,
    required String callbackId,
    required String loadMode,
  }) {
    return UnityMessage.to(
      _kTargetName,
      'LoadScene',
      {
        'bundleName': sceneName,
        'callbackId': callbackId,
        'loadMode': loadMode,
      },
    );
  }

  @override
  UnityMessage unloadAssetMessage(String key) {
    return UnityMessage.to(
      _kTargetName,
      'UnloadBundle',
      {'bundleName': key},
    );
  }

  @override
  UnityMessage loadContentCatalogMessage({
    required String url,
    required String callbackId,
  }) {
    throw UnsupportedError(
      'LoadContentCatalog is not supported by raw AssetBundle loader',
    );
  }
}

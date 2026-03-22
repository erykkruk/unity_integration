import '../../models/unity_message.dart';
import '../unity_asset_loader.dart';

/// Unity target name for the C# Addressables manager.
const String _kTargetName = 'FlutterAddressablesManager';

/// Asset loader that communicates with Unity Addressables via MessageRouter.
///
/// Sends routed messages through `FlutterBridge` which dispatches them
/// to the `FlutterAddressablesManager` C# MonoBehaviour via [MessageRouter].
///
/// This is the default loader used by [StreamingController] when no
/// explicit `assetLoader` is provided.
class UnityAddressablesLoader extends UnityAssetLoader {
  /// Creates a [UnityAddressablesLoader].
  const UnityAddressablesLoader();

  @override
  String get targetName => _kTargetName;

  @override
  UnityMessage setCachePathMessage(String cachePath) {
    return UnityMessage.routed(
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
    return UnityMessage.routed(
      _kTargetName,
      'LoadAsset',
      {
        'key': key,
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
    return UnityMessage.routed(
      _kTargetName,
      'LoadScene',
      {
        'sceneName': sceneName,
        'callbackId': callbackId,
        'loadMode': loadMode,
      },
    );
  }

  @override
  UnityMessage unloadAssetMessage(String key) {
    return UnityMessage.routed(
      _kTargetName,
      'UnloadAsset',
      {'key': key},
    );
  }

  @override
  UnityMessage loadContentCatalogMessage({
    required String url,
    required String callbackId,
  }) {
    return UnityMessage.routed(
      _kTargetName,
      'LoadContentCatalog',
      {
        'url': url,
        'callbackId': callbackId,
      },
    );
  }
}

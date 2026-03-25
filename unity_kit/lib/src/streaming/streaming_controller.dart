import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../bridge/unity_bridge.dart';
import '../utils/logger.dart';
import 'cache_manager.dart';
import 'loaders/unity_addressables_loader.dart';
import 'models/models.dart';
import 'unity_asset_loader.dart';

/// Orchestrates asset streaming: manifest fetching, downloading, caching,
/// and communication with Unity's asset loading system.
///
/// Ties together [CacheManager] for local storage, an HTTP client for
/// remote downloads, and [UnityAssetLoader] for notifying Unity when assets
/// are available.
///
/// By default, uses [UnityAddressablesLoader] (Addressables). Pass a custom
/// [assetLoader] to switch strategies (e.g. [UnityBundleLoader] for raw
/// AssetBundles).
///
/// Example:
/// ```dart
/// // Addressables (default)
/// final controller = StreamingController(
///   bridge: bridge,
///   manifestUrl: 'https://cdn.example.com/manifest.json',
/// );
///
/// // Raw AssetBundles
/// final controller = StreamingController(
///   bridge: bridge,
///   manifestUrl: 'https://cdn.example.com/manifest.json',
///   assetLoader: const UnityBundleLoader(),
/// );
///
/// await controller.initialize();
/// controller.downloadProgress.listen((p) => debugPrint(p.percentageString));
/// await controller.loadBundle('characters');
/// await controller.dispose();
/// ```
class StreamingController {
  /// Creates a [StreamingController].
  ///
  /// [bridge] is used to communicate with Unity.
  /// [manifestUrl] is the remote URL of the content manifest JSON.
  /// [assetLoader] controls which Unity asset loading strategy is used.
  /// Defaults to [UnityAddressablesLoader].
  /// [httpClient] can be injected for testing; defaults to a new [http.Client].
  /// [cacheManager] can be injected for testing; defaults to a new [CacheManager].
  StreamingController({
    required UnityBridge bridge,
    required String manifestUrl,
    UnityAssetLoader? assetLoader,
    http.Client? httpClient,
    CacheManager? cacheManager,
  })  : _bridge = bridge,
        _manifestUrl = _validateUrl(manifestUrl),
        _assetLoader = assetLoader ?? const UnityAddressablesLoader(),
        _httpClient = httpClient ?? http.Client(),
        _cacheManager = cacheManager ?? CacheManager();

  static String _validateUrl(String url) {
    final uri = Uri.parse(url);
    if (!uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw ArgumentError.value(
        url,
        'manifestUrl',
        'Must be an HTTP or HTTPS URL',
      );
    }
    return url;
  }

  final UnityBridge _bridge;
  final String _manifestUrl;
  final UnityAssetLoader _assetLoader;
  final http.Client _httpClient;
  final CacheManager _cacheManager;

  ContentManifest? _manifest;
  StreamingState _state = StreamingState.uninitialized;
  bool _isDisposed = false;

  final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();
  final StreamController<StreamingError> _errorController =
      StreamController<StreamingError>.broadcast();
  final StreamController<StreamingState> _stateController =
      StreamController<StreamingState>.broadcast();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Current state of the streaming subsystem.
  StreamingState get state => _state;

  /// Whether the controller has been disposed.
  bool get isDisposed => _isDisposed;

  /// Stream of download progress updates for individual bundles.
  Stream<DownloadProgress> get downloadProgress => _progressController.stream;

  /// Stream of errors produced during streaming operations.
  Stream<StreamingError> get errors => _errorController.stream;

  /// Stream of state transitions (e.g. initializing -> ready -> downloading).
  Stream<StreamingState> get stateChanges => _stateController.stream;

  /// The asset loader strategy used for Unity communication.
  UnityAssetLoader get assetLoader => _assetLoader;

  /// Initialize the streaming subsystem.
  ///
  /// Fetches the remote manifest, initializes the local cache, and
  /// informs Unity of the cache path so assets can be loaded from disk.
  ///
  /// Must be called before any other method. Sets [state] to
  /// [StreamingState.ready] on success or [StreamingState.error] on failure.
  Future<void> initialize() async {
    if (_isDisposed) return;
    _setState(StreamingState.initializing);

    try {
      final response = await _httpClient.get(Uri.parse(_manifestUrl));
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Failed to fetch manifest: HTTP ${response.statusCode}',
          Uri.parse(_manifestUrl),
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _manifest = ContentManifest.fromJson(json);

      UnityKitLogger.instance.debug(
        'Manifest fetched: ${_manifest!.bundleCount} bundle(s), '
        'version ${_manifest!.version}',
      );

      await _cacheManager.initialize();

      await _assetLoader.setCachePath(_bridge, _cacheManager.cachePath);

      if (_manifest!.catalogUrl != null) {
        await _assetLoader.loadContentCatalog(
          _bridge,
          url: _manifest!.catalogUrl!,
          callbackId: 'catalog_load',
        );
        UnityKitLogger.instance.info(
          'Sent LoadContentCatalog: ${_manifest!.catalogUrl}',
        );
      }

      _setState(StreamingState.ready);
      UnityKitLogger.instance.info('StreamingController initialized');
    } catch (e, stackTrace) {
      UnityKitLogger.instance.error(
        'StreamingController initialization failed',
        e,
        stackTrace,
      );
      _emitError(
        StreamingErrorType.initializationFailed,
        'Initialization failed: $e',
        e,
      );
      _setState(StreamingState.error);
    }
  }

  /// Returns the parsed content manifest, or `null` if not yet initialized.
  ContentManifest? getManifest() => _manifest;

  /// Preload bundles in the background.
  ///
  /// If [bundles] is `null`, all base bundles from the manifest are preloaded.
  /// Bundles that are already cached emit a [DownloadProgress.cached] event
  /// and are skipped.
  ///
  /// The [strategy] parameter is reserved for future network-aware
  /// download logic and currently has no effect.
  Future<void> preloadContent({
    List<String>? bundles,
    DownloadStrategy strategy = DownloadStrategy.wifiOnly,
  }) async {
    _assertReady();

    final bundleNames =
        bundles ?? _manifest!.baseBundles.map((b) => b.name).toList();

    _setState(StreamingState.downloading);

    for (final name in bundleNames) {
      if (_isDisposed) break;

      final bundle = _manifest!.getBundleByName(name);
      if (bundle == null) continue;

      if (_cacheManager.isCached(name)) {
        _progressController.add(
          DownloadProgress.cached(name, bundle.sizeBytes),
        );
        continue;
      }

      await _downloadBundle(bundle);
    }

    if (!_isDisposed) {
      _setState(StreamingState.ready);
    }
  }

  /// Load a single bundle: download if not cached, then tell Unity to load it.
  ///
  /// When a [ContentManifest.catalogUrl] is set, Unity handles bundle
  /// downloads internally via Addressables. The asset is loaded by its
  /// Addressable key (extracted from the bundle filename).
  ///
  /// Emits a [StreamingError] with [StreamingErrorType.bundleNotFound] if the
  /// bundle name does not exist in the manifest.
  Future<void> loadBundle(String bundleName) async {
    _assertReady();

    final bundle = _manifest!.getBundleByName(bundleName);
    if (bundle == null) {
      _emitError(
        StreamingErrorType.bundleNotFound,
        'Bundle not found: $bundleName',
      );
      return;
    }

    final useRemoteCatalog = _manifest!.catalogUrl != null;

    if (useRemoteCatalog) {
      // Unity handles downloads via Addressables — load by addressable key.
      final addressableKey = extractAddressableKey(bundleName, bundle: bundle);

      await _assetLoader.loadAsset(
        _bridge,
        key: addressableKey,
        callbackId: 'load_$bundleName',
      );

      UnityKitLogger.instance.debug(
        'Requested Unity to load asset: $addressableKey (bundle: $bundleName)',
      );
    } else {
      // Flutter-managed downloads — download then load by bundle name.
      if (!_cacheManager.isCached(bundleName)) {
        await _downloadBundle(bundle);
      }

      await _assetLoader.loadAsset(
        _bridge,
        key: bundleName,
        callbackId: 'load_$bundleName',
      );

      UnityKitLogger.instance.debug(
        'Requested Unity to load asset: $bundleName',
      );
    }
  }

  /// Load a Unity scene by name.
  ///
  /// Downloads the scene's bundle if it exists in the manifest and is not
  /// cached, then tells Unity to load the scene.
  ///
  /// [loadMode] controls the Unity load mode: `'Single'` replaces the
  /// current scene, `'Additive'` loads alongside it.
  Future<void> loadScene(
    String sceneName, {
    String loadMode = 'Single',
  }) async {
    _assertReady();

    final bundle = _manifest!.getBundleByName(sceneName);
    if (bundle != null && !_cacheManager.isCached(sceneName)) {
      await _downloadBundle(bundle);
    }

    await _assetLoader.loadScene(
      _bridge,
      sceneName: sceneName,
      callbackId: 'scene_$sceneName',
      loadMode: loadMode,
    );

    UnityKitLogger.instance.debug(
      'Requested Unity to load scene: $sceneName (mode: $loadMode)',
    );
  }

  /// Returns a list of all cached bundle names.
  List<String> getCachedBundles() {
    return _cacheManager.getCachedBundleNames();
  }

  /// Whether a bundle with [bundleName] is available in the local cache.
  bool isBundleCached(String bundleName) {
    return _cacheManager.isCached(bundleName);
  }

  /// Total size of all cached content in bytes.
  int getCacheSize() {
    return _cacheManager.getCacheSize();
  }

  /// Delete all locally cached content.
  Future<void> clearCache() async {
    await _cacheManager.clearCache();
    UnityKitLogger.instance.info('Streaming cache cleared');
  }

  /// Cancel all in-flight downloads.
  ///
  /// Currently a placeholder; will integrate with a dedicated
  /// [ContentDownloader] when available.
  void cancelDownloads() {
    UnityKitLogger.instance.debug('cancelDownloads called (no-op for now)');
  }

  /// Dispose all resources held by this controller.
  ///
  /// After calling [dispose], the controller cannot be reused.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    _httpClient.close();
    await _progressController.close();
    await _errorController.close();
    await _stateController.close();

    UnityKitLogger.instance.debug('StreamingController disposed');
  }

  // ---------------------------------------------------------------------------
  // Addressable key extraction
  // ---------------------------------------------------------------------------

  /// Extracts the Addressable address from a bundle.
  ///
  /// Resolution order:
  /// 1. `bundle.metadata['addressableKeys']` — if the manifest contains
  ///    keys generated by [AddressablesManifestBuilder], use the first one.
  /// 2. Regex extraction from the bundle filename. Format:
  ///    `{group}_{address}_{32hexhash}.bundle`
  ///    Example: `toys_assets_lightsaber_3f71d67081ae536817cceba29b951a9d.bundle`
  ///          -> `lightsaber`
  /// 3. Raw bundle name as last resort.
  static String extractAddressableKey(
    String bundleName, {
    ContentBundle? bundle,
  }) {
    // 1. Metadata lookup
    if (bundle != null) {
      final keys = bundle.metadata?['addressableKeys'];
      if (keys is List && keys.isNotEmpty) {
        return keys.first as String;
      }
    }

    // 2. Regex extraction from filename
    var name = bundleName.replaceAll('.bundle', '');
    final stripped = name.replaceFirst(RegExp(r'_[a-f0-9]{32}$'), '');
    if (stripped != name) {
      name = stripped;
    }
    final withoutPrefix =
        name.replaceFirst(RegExp(r'^[a-z]+_assets_'), '');
    if (withoutPrefix != name && withoutPrefix.isNotEmpty) {
      return withoutPrefix;
    }

    // 3. Fallback — return cleaned name
    return name;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Downloads a single [bundle] using a streamed HTTP request.
  ///
  /// Emits [DownloadProgress] events as chunks arrive, and caches the
  /// completed download via [CacheManager].
  Future<void> _downloadBundle(ContentBundle bundle) async {
    try {
      final bundleUri = Uri.parse(bundle.url);
      if (!bundleUri.hasScheme ||
          (!bundleUri.isScheme('http') && !bundleUri.isScheme('https'))) {
        throw ArgumentError('Invalid bundle URL: ${bundle.url}');
      }

      final request = http.Request('GET', bundleUri);
      final streamedResponse = await _httpClient.send(request);

      if (streamedResponse.statusCode != 200) {
        throw http.ClientException(
          'HTTP ${streamedResponse.statusCode}',
          bundleUri,
        );
      }

      var downloaded = 0;
      final bytesBuilder = BytesBuilder(copy: false);

      await for (final chunk in streamedResponse.stream) {
        if (_isDisposed) break;

        bytesBuilder.add(chunk);
        downloaded += chunk.length;

        _progressController.add(DownloadProgress(
          bundleName: bundle.name,
          downloadedBytes: downloaded,
          totalBytes: bundle.sizeBytes,
          state: DownloadState.downloading,
        ));
      }

      if (_isDisposed) return;

      await _cacheManager.cacheBundle(
        bundle.name,
        bytesBuilder.takeBytes(),
        sha256Hash: bundle.sha256,
      );

      _progressController.add(
        DownloadProgress.completed(bundle.name, bundle.sizeBytes),
      );

      UnityKitLogger.instance.debug(
        'Downloaded and cached bundle: ${bundle.name} '
        '(${bundle.formattedSize})',
      );
    } catch (e, stackTrace) {
      UnityKitLogger.instance.error(
        'Failed to download bundle: ${bundle.name}',
        e,
        stackTrace,
      );
      _progressController.add(
        DownloadProgress.failed(bundle.name, error: e.toString()),
      );
      _emitError(
        StreamingErrorType.downloadFailed,
        'Download failed: ${bundle.name}',
        e,
      );
    }
  }

  /// Transitions to [newState] and notifies listeners.
  void _setState(StreamingState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Emits a structured error to the [errors] stream.
  void _emitError(
    StreamingErrorType type,
    String message, [
    Object? cause,
  ]) {
    if (!_errorController.isClosed) {
      _errorController.add(StreamingError(
        type: type,
        message: message,
        cause: cause,
      ));
    }
  }

  /// Throws [StateError] if the controller is not initialized.
  void _assertReady() {
    if (_isDisposed) {
      throw StateError('StreamingController has been disposed');
    }
    if (_manifest == null || _state == StreamingState.uninitialized) {
      throw StateError(
        'StreamingController not initialized. Call initialize() first.',
      );
    }
  }
}

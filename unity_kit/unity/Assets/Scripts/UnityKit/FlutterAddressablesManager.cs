using System;
using System.Collections;
using UnityEngine;

#if ADDRESSABLES_INSTALLED
using UnityEngine.AddressableAssets;
using UnityEngine.ResourceManagement.AsyncOperations;
using UnityEngine.ResourceManagement.ResourceLocations;
using UnityEngine.SceneManagement;
#endif

namespace UnityKit
{
    // -----------------------------------------------------------------------
    // Request / Response DTOs for Flutter communication
    // -----------------------------------------------------------------------

    /// <summary>
    /// Request to load an Addressable asset by key.
    /// </summary>
    [Serializable]
    public class LoadAssetRequest
    {
        public string key;
        public string callbackId;
    }

    /// <summary>
    /// Request to load an Addressable scene.
    /// </summary>
    [Serializable]
    public class LoadSceneRequest
    {
        public string sceneName;
        public string callbackId;
        /// <summary>"Single" or "Additive".</summary>
        public string loadMode;
    }

    /// <summary>
    /// Response sent to Flutter after an asset load completes.
    /// </summary>
    [Serializable]
    public class AssetLoadedResponse
    {
        public string callbackId;
        public string key;
        public bool success;
        public string error;
    }

    /// <summary>
    /// Response sent to Flutter after a scene load completes.
    /// </summary>
    [Serializable]
    public class SceneLoadedResponse
    {
        public string callbackId;
        public string sceneName;
        public bool success;
        public string error;
    }

    /// <summary>
    /// Progress update sent to Flutter during long-running operations.
    /// </summary>
    [Serializable]
    public class ProgressResponse
    {
        public string callbackId;
        /// <summary>Normalised progress value (0.0 - 1.0).</summary>
        public float progress;
        public string status;
    }

    /// <summary>
    /// Request to load a remote content catalog by URL.
    /// </summary>
    [Serializable]
    public class LoadContentCatalogRequest
    {
        public string url;
        public string callbackId;
    }

    /// <summary>
    /// Error response sent to Flutter when an operation fails.
    /// </summary>
    [Serializable]
    public class ErrorResponse
    {
        public string callbackId;
        public string error;
        public string errorType;
    }

    // -----------------------------------------------------------------------
    // FlutterAddressablesManager
    // -----------------------------------------------------------------------

    /// <summary>
    /// Manages Unity Addressables integration with Flutter asset streaming.
    ///
    /// <para>
    /// Receives cache paths from Flutter and loads assets / scenes from them.
    /// Registers itself with <see cref="MessageRouter"/> under the target name
    /// <c>"FlutterAddressablesManager"</c>.
    /// </para>
    ///
    /// <para>
    /// Uses conditional compilation (<c>#if ADDRESSABLES_INSTALLED</c>) so the
    /// project compiles even without the Addressables package installed. When
    /// the package is absent every load operation returns a descriptive error
    /// to Flutter instead of silently failing.
    /// </para>
    ///
    /// <para>
    /// <b>Supported messages:</b>
    /// <list type="bullet">
    ///   <item><c>SetCachePath</c> - configure the local cache directory</item>
    ///   <item><c>LoadAsset</c>    - load a <c>GameObject</c> by Addressable key</item>
    ///   <item><c>LoadScene</c>    - load a scene (Single / Additive)</item>
    ///   <item><c>UnloadAsset</c>  - release an asset by key</item>
    ///   <item><c>UpdateCatalog</c>- refresh the Addressables catalog</item>
    ///   <item><c>LoadContentCatalog</c> - load a remote content catalog by URL</item>
    /// </list>
    /// </para>
    /// </summary>
    public class FlutterAddressablesManager : MonoBehaviour
    {
        // -------------------------------------------------------------------
        // Singleton
        // -------------------------------------------------------------------

        /// <summary>Singleton instance.</summary>
        public static FlutterAddressablesManager Instance { get; private set; }

        // -------------------------------------------------------------------
        // Constants
        // -------------------------------------------------------------------

        private const string TARGET_NAME = "FlutterAddressablesManager";
        private const string METHOD_SET_CACHE_PATH = "SetCachePath";
        private const string METHOD_LOAD_ASSET = "LoadAsset";
        private const string METHOD_LOAD_SCENE = "LoadScene";
        private const string METHOD_UNLOAD_ASSET = "UnloadAsset";
        private const string METHOD_UPDATE_CATALOG = "UpdateCatalog";
        private const string METHOD_LOAD_CONTENT_CATALOG = "LoadContentCatalog";

        private const string STATUS_LOADING = "loading";
        private const string STATUS_LOADING_SCENE = "loading_scene";
        private const string ERROR_TYPE_NOT_INSTALLED = "not_installed";
        private const string ERROR_NOT_INITIALIZED = "FlutterAddressablesManager not initialized. Call SetCachePath first.";
        private const string ERROR_ADDRESSABLES_NOT_INSTALLED = "Addressables package not installed";

        private const string LOAD_MODE_ADDITIVE = "Additive";
        private const string CATALOG_UPDATE_CALLBACK_ID = "catalog_update";

        // -------------------------------------------------------------------
        // State
        // -------------------------------------------------------------------

        private string _cachePath;
        private bool _isInitialized;
        private string _loadedCatalogUrl;

        /// <summary>Whether the manager has been initialised with a cache path.</summary>
        public bool IsInitialized => _isInitialized;

        // -------------------------------------------------------------------
        // Lifecycle
        // -------------------------------------------------------------------

        private void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Destroy(gameObject);
                return;
            }

            Instance = this;
            DontDestroyOnLoad(gameObject);
        }

        private void OnEnable()
        {
            MessageRouter.Register(TARGET_NAME, HandleMessage);
        }

        private void OnDisable()
        {
            MessageRouter.Unregister(TARGET_NAME);
        }

        private void OnDestroy()
        {
            if (Instance == this)
            {
                Instance = null;
            }
        }

        // -------------------------------------------------------------------
        // Message handling
        // -------------------------------------------------------------------

        private void HandleMessage(string method, string data)
        {
            switch (method)
            {
                case METHOD_SET_CACHE_PATH:
                    SetCachePath(data);
                    break;

                case METHOD_LOAD_ASSET:
                    HandleLoadAsset(data);
                    break;

                case METHOD_LOAD_SCENE:
                    HandleLoadScene(data);
                    break;

                case METHOD_UNLOAD_ASSET:
                    UnloadAsset(data);
                    break;

                case METHOD_UPDATE_CATALOG:
                    StartCoroutine(UpdateCatalogCoroutine(data));
                    break;

                case METHOD_LOAD_CONTENT_CATALOG:
                    HandleLoadContentCatalog(data);
                    break;

                default:
                    UnityKitLogger.Warning($"FlutterAddressablesManager: Unknown method '{method}'");
                    break;
            }
        }

        private void HandleLoadAsset(string data)
        {
            var request = JsonUtility.FromJson<LoadAssetRequest>(data);
            if (request == null)
            {
                UnityKitLogger.Error($"FlutterAddressablesManager: Failed to parse LoadAssetRequest");
                return;
            }

            if (!_isInitialized)
            {
                SendError(request.callbackId, ERROR_NOT_INITIALIZED, "not_initialized");
                return;
            }

            StartCoroutine(LoadAssetCoroutine(request.key, request.callbackId));
        }

        private void HandleLoadScene(string data)
        {
            var request = JsonUtility.FromJson<LoadSceneRequest>(data);
            if (request == null)
            {
                UnityKitLogger.Error($"FlutterAddressablesManager: Failed to parse LoadSceneRequest");
                return;
            }

            if (!_isInitialized)
            {
                SendError(request.callbackId, ERROR_NOT_INITIALIZED, "not_initialized");
                return;
            }

            StartCoroutine(LoadSceneCoroutine(request.sceneName, request.callbackId, request.loadMode));
        }

        private void HandleLoadContentCatalog(string data)
        {
            var request = JsonUtility.FromJson<LoadContentCatalogRequest>(data);
            if (request == null)
            {
                UnityKitLogger.Error($"FlutterAddressablesManager: Failed to parse LoadContentCatalogRequest");
                return;
            }

            if (string.IsNullOrEmpty(request.url))
            {
                SendError(request.callbackId, "Catalog URL cannot be null or empty", "invalid_argument");
                return;
            }

            if (_loadedCatalogUrl == request.url)
            {
                UnityKitLogger.Info($"FlutterAddressablesManager: Catalog already loaded from this URL, skipping");
                var response = new AssetLoadedResponse
                {
                    callbackId = request.callbackId,
                    key = request.url,
                    success = true,
                    error = "",
                };
                NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
                return;
            }

            StartCoroutine(LoadContentCatalogCoroutine(request.url, request.callbackId));
        }

        // -------------------------------------------------------------------
        // Cache path configuration
        // -------------------------------------------------------------------

        /// <summary>
        /// Set the local cache directory used to resolve remote Addressable URLs.
        /// Must be called before any load operations.
        /// </summary>
        public void SetCachePath(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                UnityKitLogger.Error($"FlutterAddressablesManager: Cache path cannot be null or empty");
                return;
            }

            _cachePath = System.IO.Path.GetFullPath(path);
            _isInitialized = true;
            UnityKitLogger.Info($"FlutterAddressablesManager: Cache path set");

#if ADDRESSABLES_INSTALLED
            // Redirect remote Addressable URLs to the Flutter-managed cache.
            Addressables.InternalIdTransformFunc = TransformInternalId;
#endif
        }

        // -------------------------------------------------------------------
        // Helpers
        // -------------------------------------------------------------------

        private void SendError(string callbackId, string error, string errorType)
        {
            var response = new ErrorResponse
            {
                callbackId = callbackId,
                error = error,
                errorType = errorType,
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

        private void SendProgress(string callbackId, float progress, string status)
        {
            var response = new ProgressResponse
            {
                callbackId = callbackId,
                progress = progress,
                status = status,
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

        // ===================================================================
        // Addressables-dependent implementation
        // ===================================================================

#if ADDRESSABLES_INSTALLED

        /// <summary>
        /// Transforms remote Addressable URLs to local cache paths when the
        /// corresponding file has already been downloaded by Flutter.
        /// </summary>
        private string TransformInternalId(IResourceLocation location)
        {
            if (string.IsNullOrEmpty(_cachePath))
            {
                return location.InternalId;
            }

            // Only redirect remote HTTP(S) URLs.
            if (!location.InternalId.StartsWith("http", StringComparison.OrdinalIgnoreCase))
            {
                return location.InternalId;
            }

            var fileName = System.IO.Path.GetFileName(new Uri(location.InternalId).AbsolutePath);
            var cachedPath = System.IO.Path.Combine(_cachePath, fileName);

            if (System.IO.File.Exists(cachedPath))
            {
                UnityKitLogger.Info($"FlutterAddressablesManager: Redirecting '{fileName}' to cache");
                return cachedPath;
            }

            return location.InternalId;
        }

        // -------------------------------------------------------------------
        // Load asset
        // -------------------------------------------------------------------

        private IEnumerator LoadAssetCoroutine(string key, string callbackId)
        {
            var handle = Addressables.LoadAssetAsync<GameObject>(key);

            while (!handle.IsDone)
            {
                SendProgress(callbackId, handle.PercentComplete, STATUS_LOADING);
                yield return null;
            }

            var succeeded = handle.Status == AsyncOperationStatus.Succeeded;

            var response = new AssetLoadedResponse
            {
                callbackId = callbackId,
                key = key,
                success = succeeded,
                error = succeeded ? "" : (handle.OperationException?.Message ?? "Unknown error"),
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

        // -------------------------------------------------------------------
        // Load scene
        // -------------------------------------------------------------------

        private IEnumerator LoadSceneCoroutine(string sceneName, string callbackId, string loadMode)
        {
            var mode = loadMode == LOAD_MODE_ADDITIVE
                ? LoadSceneMode.Additive
                : LoadSceneMode.Single;

            var handle = Addressables.LoadSceneAsync(sceneName, mode);

            while (!handle.IsDone)
            {
                SendProgress(callbackId, handle.PercentComplete, STATUS_LOADING_SCENE);
                yield return null;
            }

            var succeeded = handle.Status == AsyncOperationStatus.Succeeded;

            var response = new SceneLoadedResponse
            {
                callbackId = callbackId,
                sceneName = sceneName,
                success = succeeded,
                error = succeeded ? "" : (handle.OperationException?.Message ?? "Unknown error"),
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

        // -------------------------------------------------------------------
        // Unload asset
        // -------------------------------------------------------------------

        private void UnloadAsset(string key)
        {
            // Addressables uses reference counting; releasing by key is not
            // directly supported. Callers must hold the handle. Log for
            // traceability.
            UnityKitLogger.Info($"FlutterAddressablesManager: Unload requested for asset: {key}");
        }

        // -------------------------------------------------------------------
        // Load content catalog
        // -------------------------------------------------------------------

        private IEnumerator LoadContentCatalogCoroutine(string url, string callbackId)
        {
            UnityKitLogger.Info($"FlutterAddressablesManager: Loading content catalog from: {url}");

            var handle = Addressables.LoadContentCatalogAsync(url);

            while (!handle.IsDone)
            {
                SendProgress(callbackId, handle.PercentComplete, STATUS_LOADING);
                yield return null;
            }

            var succeeded = handle.Status == AsyncOperationStatus.Succeeded;

            if (succeeded)
            {
                _loadedCatalogUrl = url;
                UnityKitLogger.Info($"FlutterAddressablesManager: Content catalog loaded successfully");
            }
            else
            {
                UnityKitLogger.Error($"FlutterAddressablesManager: Failed to load content catalog: {handle.OperationException?.Message}");
            }

            var response = new AssetLoadedResponse
            {
                callbackId = callbackId,
                key = url,
                success = succeeded,
                error = succeeded ? "" : (handle.OperationException?.Message ?? "Unknown error"),
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

        // -------------------------------------------------------------------
        // Update catalog
        // -------------------------------------------------------------------

        private IEnumerator UpdateCatalogCoroutine(string catalogUrl)
        {
            var handle = Addressables.UpdateCatalogs();
            yield return handle;

            var succeeded = handle.Status == AsyncOperationStatus.Succeeded;

            var response = new AssetLoadedResponse
            {
                callbackId = CATALOG_UPDATE_CALLBACK_ID,
                key = catalogUrl,
                success = succeeded,
                error = succeeded ? "" : (handle.OperationException?.Message ?? "Unknown error"),
            };
            NativeAPI.SendToFlutter(JsonUtility.ToJson(response));
        }

#else
        // ===================================================================
        // Stub implementations (Addressables NOT installed)
        // ===================================================================

        private IEnumerator LoadAssetCoroutine(string key, string callbackId)
        {
            UnityKitLogger.Warning($"FlutterAddressablesManager: {ERROR_ADDRESSABLES_NOT_INSTALLED}. Cannot load asset '{key}'.");
            SendError(callbackId, ERROR_ADDRESSABLES_NOT_INSTALLED, ERROR_TYPE_NOT_INSTALLED);
            yield break;
        }

        private IEnumerator LoadSceneCoroutine(string sceneName, string callbackId, string loadMode)
        {
            UnityKitLogger.Warning($"FlutterAddressablesManager: {ERROR_ADDRESSABLES_NOT_INSTALLED}. Cannot load scene '{sceneName}'.");
            SendError(callbackId, ERROR_ADDRESSABLES_NOT_INSTALLED, ERROR_TYPE_NOT_INSTALLED);
            yield break;
        }

        private void UnloadAsset(string key)
        {
            UnityKitLogger.Warning($"FlutterAddressablesManager: {ERROR_ADDRESSABLES_NOT_INSTALLED}. Cannot unload asset '{key}'.");
        }

        private IEnumerator LoadContentCatalogCoroutine(string url, string callbackId)
        {
            UnityKitLogger.Warning($"FlutterAddressablesManager: {ERROR_ADDRESSABLES_NOT_INSTALLED}. Cannot load content catalog.");
            SendError(callbackId, ERROR_ADDRESSABLES_NOT_INSTALLED, ERROR_TYPE_NOT_INSTALLED);
            yield break;
        }

        private IEnumerator UpdateCatalogCoroutine(string catalogUrl)
        {
            UnityKitLogger.Warning($"FlutterAddressablesManager: {ERROR_ADDRESSABLES_NOT_INSTALLED}. Cannot update catalog.");
            SendError(CATALOG_UPDATE_CALLBACK_ID, ERROR_ADDRESSABLES_NOT_INSTALLED, ERROR_TYPE_NOT_INSTALLED);
            yield break;
        }

#endif
    }
}

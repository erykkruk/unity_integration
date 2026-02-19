# Unity Content Loading & Generation Guide

> This document describes **all** the ways to generate, load, and manage 3D content with Unity — both in the context of Flutter-Unity embedding (unity_kit) and native iOS/Android platforms.

---

## Table of Contents

1. [Overview of Options](#1-overview-of-options)
2. [Scene Loading](#2-scene-loading)
3. [Loading Individual Models/Prefabs](#3-loading-individual-modelsprefabs)
4. [AssetBundles](#4-assetbundles)
5. [Addressables](#5-addressables)
6. [glTF/GLB — Runtime Import](#6-gltfglb--runtime-import)
7. [Runtime Mesh Generation](#7-runtime-mesh-generation)
8. [Asset Streaming & LOD](#8-asset-streaming--lod)
9. [Remote Configuration](#9-remote-configuration)
10. [Hot Content Updates (Without Store Submission)](#10-hot-content-updates-without-store-submission)
11. [AR Foundation](#11-ar-foundation)
12. [Platform Differences (iOS vs Android)](#12-platform-differences-ios-vs-android)
13. [Integration with unity_kit](#13-integration-with-unity_kit)

---

## 1. Overview of Options

| Approach | Asset Loading | Code Loading | iOS Safe | Android Safe | Complexity | Best For |
|----------|:-:|:-:|:-:|:-:|:-:|---------|
| **Scene Loading** | Built-in | No | Yes | Yes | Low | Switching game contexts |
| **Prefab Instantiation** | Yes | No | Yes | Yes | Low | Loading individual models on-demand |
| **AssetBundles** | Yes | No | Yes | Yes | High | Legacy projects, full control |
| **Addressables + CCD** | Yes | No | Yes | Yes | Medium | Primary content delivery system |
| **glTF/GLB Runtime** | Yes | No | Yes | Yes | Medium | User-generated content, NFTs, external 3D |
| **Runtime Mesh Gen** | N/A | No | Yes | Yes | Medium-High | Procedural content |
| **Remote Config** | Config only | No | Yes | Yes | Low | Feature flags, tuning, A/B testing |
| **HybridCLR** | Yes | **Yes** | Gray area | Yes | High | Code hot-fixes (use cautiously on iOS) |
| **AR Foundation** | N/A | No | Yes | Yes | Medium | AR camera experiences |

---

## 2. Scene Loading

### What Is It?

Unity SceneManager allows loading entire scenes at runtime — either **replacing** the current scene or **additively** (layer upon layer). A scene in Unity is a container holding GameObjects, their components, lighting, lightmaps, navmesh, skybox, and other environment settings. A scene = a `.unity` file in the editor.

### Loading Modes

```
┌──────────────────────────────────────────────────────────────────────┐
│  LoadSceneMode.Single                                                │
│  ─────────────────────                                               │
│  Replaces the ENTIRE current scene with a new one. All GameObjects   │
│  from the previous scene are destroyed (unless they have             │
│  DontDestroyOnLoad). Lightmaps, navmesh, skybox — everything        │
│  comes from the new scene.                                           │
│                                                                       │
│  Use: transitioning from main menu to gameplay, between levels.      │
├──────────────────────────────────────────────────────────────────────┤
│  LoadSceneMode.Additive                                               │
│  ─────────────────────                                               │
│  Adds a new scene TO the existing one. Both sets of GameObjects      │
│  coexist. Each loaded scene has its own root in the hierarchy.       │
│  Only ONE scene is "active" (active scene) — newly created           │
│  objects go into the active scene.                                    │
│                                                                       │
│  Use: modular design, UI overlays, streaming open world.             │
└──────────────────────────────────────────────────────────────────────┘
```

### How Does It Work?

**C# (Unity) — full examples:**

```csharp
// ═══════════════════════════════════════════════════════
// 1. SYNCHRONOUS (blocks the main thread — NOT for mobile)
// ═══════════════════════════════════════════════════════
SceneManager.LoadScene("GameShowroom", LoadSceneMode.Single);
// The entire frame is blocked until loading completes.
// On mobile = UI freeze, possible ANR (Application Not Responding).

// ═══════════════════════════════════════════════════════
// 2. ASYNCHRONOUS — basic (recommended on mobile)
// ═══════════════════════════════════════════════════════
AsyncOperation op = SceneManager.LoadSceneAsync("GameShowroom", LoadSceneMode.Additive);

// Scene loads in the background — Unity allocates time per frame.
// progress: 0.0 → 0.9 = loading, 0.9 = ready for activation.
op.completed += (asyncOp) => {
    Debug.Log("Scene GameShowroom loaded!");
};

// ═══════════════════════════════════════════════════════
// 3. ASYNCHRONOUS with loading screen (production)
// ═══════════════════════════════════════════════════════
IEnumerator LoadSceneWithProgress(string sceneName)
{
    // Show loading screen
    loadingScreen.SetActive(true);
    progressBar.value = 0f;

    AsyncOperation op = SceneManager.LoadSceneAsync(sceneName, LoadSceneMode.Additive);
    op.allowSceneActivation = false; // Wait — do not activate immediately

    while (!op.isDone)
    {
        // progress goes from 0.0 to 0.9 (90% = loaded in memory)
        float progress = Mathf.Clamp01(op.progress / 0.9f);
        progressBar.value = progress;

        // Send progress to Flutter
        NativeAPI.SendToFlutter(JsonUtility.ToJson(new {
            type = "scene_loading_progress",
            sceneName = sceneName,
            progress = progress
        }));

        if (op.progress >= 0.9f)
        {
            // Scene ready — activate (this triggers Awake/Start on objects)
            op.allowSceneActivation = true;
        }

        yield return null; // Wait one frame
    }

    // Set as active scene (new objects go here)
    SceneManager.SetActiveScene(SceneManager.GetSceneByName(sceneName));

    loadingScreen.SetActive(false);
}

// ═══════════════════════════════════════════════════════
// 4. UNLOADING a scene (CRITICAL on mobile — memory!)
// ═══════════════════════════════════════════════════════
IEnumerator UnloadScene(string sceneName)
{
    AsyncOperation op = SceneManager.UnloadSceneAsync(sceneName);
    yield return op;

    // After unloading the scene, assets may still remain in memory!
    // Resources.UnloadUnusedAssets() cleans up orphaned assets.
    yield return Resources.UnloadUnusedAssets();

    // Force GC (optional, but recommended after a large unload)
    System.GC.Collect();
}

// ═══════════════════════════════════════════════════════
// 5. MANAGING multiple additive scenes
// ═══════════════════════════════════════════════════════
public class SceneController : MonoBehaviour
{
    private readonly Dictionary<string, bool> _loadedScenes = new();

    public async void LoadSceneIfNeeded(string sceneName)
    {
        if (_loadedScenes.ContainsKey(sceneName)) return;

        _loadedScenes[sceneName] = true;
        var op = SceneManager.LoadSceneAsync(sceneName, LoadSceneMode.Additive);
        await op; // Unity 2023+ async/await support
    }

    public async void UnloadIfLoaded(string sceneName)
    {
        if (!_loadedScenes.ContainsKey(sceneName)) return;

        _loadedScenes.Remove(sceneName);
        await SceneManager.UnloadSceneAsync(sceneName);
        await Resources.UnloadUnusedAssets();
    }

    // Swap one scene for another
    public async void SwapScene(string oldScene, string newScene)
    {
        // Load the new one BEFORE unloading the old one — avoids "empty frame"
        await SceneManager.LoadSceneAsync(newScene, LoadSceneMode.Additive);
        SceneManager.SetActiveScene(SceneManager.GetSceneByName(newScene));

        if (_loadedScenes.ContainsKey(oldScene))
        {
            await SceneManager.UnloadSceneAsync(oldScene);
            _loadedScenes.Remove(oldScene);
        }
        _loadedScenes[newScene] = true;

        await Resources.UnloadUnusedAssets();
    }
}
```

**Dart (Flutter -> Unity via unity_kit bridge):**

```dart
// ═══════════════════════════════════════════════════════
// Flutter: sending scene commands to Unity
// ═══════════════════════════════════════════════════════

// Load scene (additive)
bridge.send(UnityMessage.command('LoadScene', {
  'sceneName': 'GameShowroom',
  'mode': 'additive',  // or 'single'
}));

// Unload scene
bridge.send(UnityMessage.command('UnloadScene', {
  'sceneName': 'ItemCollection',
}));

// Swap scene
bridge.send(UnityMessage.command('SwapScene', {
  'oldScene': 'ItemCollection',
  'newScene': 'GameShowroom',
}));

// ═══════════════════════════════════════════════════════
// Flutter: listening for scene events
// ═══════════════════════════════════════════════════════

// Track scene loading (progress bar in Flutter)
bridge.messageStream
  .where((msg) => msg.type == 'scene_loading_progress')
  .listen((msg) {
    final progress = msg.data?['progress'] as double? ?? 0;
    final sceneName = msg.data?['sceneName'] as String? ?? '';
    setState(() {
      _loadingProgress = progress;
      _loadingScene = sceneName;
    });
  });

// Scene loaded
bridge.sceneStream.listen((SceneInfo info) {
  debugPrint('Scene ${info.name} loaded');
  debugPrint('  buildIndex: ${info.buildIndex}');
  debugPrint('  isLoaded: ${info.isLoaded}');
  debugPrint('  isValid: ${info.isValid}');

  // Update Flutter application state
  context.read<SceneCubit>().onSceneLoaded(info);
});

// Scene unloaded
bridge.messageStream
  .where((msg) => msg.type == 'scene_unloaded')
  .listen((msg) {
    context.read<SceneCubit>().onSceneUnloaded(msg.data?['sceneName']);
  });
```

### Additive Loading — The Key to Modularity

Additive scenes allow creating a modular architecture. The key principle: **one persistent scene + swappable modules**.

```
Base scene "Core" (persistent — NEVER unloaded):
├── Main Camera (with CinemachineBrain)
├── Global Light (Directional)
├── EventSystem
├── AudioManager (DontDestroyOnLoad)
├── FlutterBridge (singleton)
├── SceneController
└── GameManager
     └── RemoteConfigManager

+ Additive scene "ModelViewer":            ← loaded when user opens a model
  ├── ModelPedestal (prefab)
  ├── ModelSpotlight (Point Light)
  ├── ModelAnimationController
  ├── CinemachineVirtualCamera (orbit)
  ├── PostProcessVolume (model-specific)
  └── ModelInteractionHandler

+ Additive scene "ItemCollection":         ← another additive scene
  ├── GridLayout (3D grid)
  ├── ScrollSystem
  ├── CollectionCamera (virtual cam)
  ├── ThumbnailRenderer
  └── CollectionManager

+ Additive scene "ItemCustomizer":         ← customize flow
  ├── CustomizePedestal
  ├── MaterialPicker
  ├── ColorWheel
  ├── CustomizeCamera
  └── UndoRedoManager

+ Additive scene "ARExperience":           ← AR mode
  ├── ARSession
  ├── ARSessionOrigin
  ├── ARPlaneManager
  ├── ARRaycastManager
  └── ARModelPlacer
```

**Why this architecture?**

| Benefit | Description |
|---------|-------------|
| **Isolation** | Each module has its own lighting, camera, post-processing |
| **Memory** | Unloading a module frees its assets |
| **Collaboration** | Different artists work on different scenes without merge conflicts |
| **Testing** | Each module can be opened separately in the editor |
| **Build size** | Modules can be in Addressables (not in the base build) |

**Note about Active Scene:**

```csharp
// IMPORTANT: only one scene is "active" at a time.
// Newly created objects (Instantiate without parent) go into the active scene.
// Lighting and skybox of the CURRENT active scene are used.

SceneManager.SetActiveScene(SceneManager.GetSceneByName("ModelViewer"));
// Now lighting from ModelViewer is dominant
// Instantiate() without parent creates objects in ModelViewer
```

### Scene Sources — Where Can They Be Loaded From?

| Source | How to Load | When to Use |
|--------|-------------|-------------|
| **Build Settings** | `SceneManager.LoadSceneAsync("name")` | Scenes built into the app (core, menu) |
| **AssetBundle** | First `AssetBundle.LoadFromFile()`, then `SceneManager.LoadSceneAsync()` | Legacy, full control |
| **Addressables** | `Addressables.LoadSceneAsync("address")` | Recommended — manages bundles automatically |
| **Addressables Remote** | Same as above, but group has remote build path | New scenes without app update |

```csharp
// ═══ From Build Settings ═══
SceneManager.LoadSceneAsync("GameShowroom", LoadSceneMode.Additive);
// Scene MUST be in File > Build Settings > Scenes In Build

// ═══ From AssetBundle ═══
// Step 1: load the bundle containing the scene
AssetBundle sceneBundle = AssetBundle.LoadFromFile(
    Path.Combine(Application.persistentDataPath, "scenes/gameshowroom")
);
// Step 2: load the scene from the bundle (by name, not path)
SceneManager.LoadSceneAsync("GameShowroom", LoadSceneMode.Additive);
// Step 3: unload the bundle after loading the scene
sceneBundle.Unload(false);

// ═══ From Addressables ═══
var sceneHandle = Addressables.LoadSceneAsync(
    "Scenes/GameShowroom",
    LoadSceneMode.Additive,
    activateOnLoad: true
);
// sceneHandle.Result = SceneInstance (for later unload)
SceneInstance sceneInstance = await sceneHandle.Task;

// Unloading:
Addressables.UnloadSceneAsync(sceneHandle);
```

### Lightmaps and Static Data in Additive Scenes

**Problem:** Lightmaps, reflection probes, and navmesh are per-scene. With additive loading they can conflict.

**Solutions:**

| Problem | Solution |
|---------|----------|
| Lightmaps from two scenes mix together | Bake lightmaps separately per scene. Each scene has its own LightmapData. Unity automatically manages offsets |
| Two scenes have different skyboxes | Set skybox on the active scene. `SceneManager.SetActiveScene()` switches the skybox |
| Navmesh does not connect between scenes | Use `NavMeshSurface` component (from AI Navigation package) — builds navmesh at runtime, can merge multiple scenes |
| Reflection probes duplicate | Disable probes in inactive scenes, or use different masks |

### Pros and Cons

| Pros | Cons |
|------|------|
| Full context switching — change the entire world at once | Scenes in Build Settings increase APK/IPA size |
| Async loading = zero lag with correct implementation | Large scenes = memory spikes (peak RAM during loading) |
| Additive = modularity, isolation, team collaboration | Lightmaps/navmesh/reflection probes require management |
| Works identically in Flutter embed | Only one scene "active" at a time (skybox, lighting) |
| Scenes from Addressables = remote loading | Synchronous LoadScene blocks UI (use Async!) |
| Progress tracking (`AsyncOperation.progress`) | Awake/Start on scene objects can cause spikes if there are many |
| Swap pattern (load new -> unload old) | `Resources.UnloadUnusedAssets()` after unload is slow (50-200ms) |

### Platform Notes

**iOS:**
- SceneManager works identically in Flutter embed. Unity player has its own game loop.
- **Peak memory**: While loading a new scene (before unloading the old one), both scenes are in RAM. On an iPhone with 3GB RAM this is critical — plan swaps carefully.
- **allowSceneActivation = false**: The scene is 90% loaded in memory, but objects do not yet have Awake/Start. This is a good moment to show a loading screen.

**Android:**
- Identical behavior to iOS. Watch out for low-end devices with 2GB RAM.
- **ANR (Application Not Responding)**: Synchronous `LoadScene` on a large scene = ANR dialog after 5 seconds. ALWAYS use `LoadSceneAsync`.

**Flutter-specific:**
- Unity scene state is **invisible** to Flutter — Unity must send a return message.
- unity_kit handles this automatically: `SceneTracker.cs` hooks `SceneManager.sceneLoaded` / `sceneUnloaded` and sends events to Flutter via `NativeAPI.NotifySceneLoaded()`.
- Flutter listens on `bridge.sceneStream` -> `SceneInfo` with name, buildIndex, isLoaded, isValid.
- **Loading UI**: Show a loading screen in Flutter (Dart widget) while Unity loads the scene. Listen for progress messages from Unity.

---

## 3. Loading Individual Models/Prefabs

### What Is It?

Loading and instantiating individual 3D models (prefabs) into an **already running scene** — without loading an entire new scene. A prefab in Unity is a "template" of a GameObject with components (mesh, materials, animations, scripts, colliders, etc.). A single prefab can be instantiated multiple times.

**Key difference vs scenes:** Scene = the entire context (lighting, camera, everything). Prefab = a single object placed into an existing context.

### How Does It Work? — All Methods

```csharp
// ═══════════════════════════════════════════════════════
// METHOD 1: Addressables — RECOMMENDED
// ═══════════════════════════════════════════════════════

// A. Load + Instantiate separately (when you need a reference to the prefab)
var loadHandle = Addressables.LoadAssetAsync<GameObject>("Models/Model_001");
GameObject prefab = await loadHandle.Task;

// Instantiate multiple times from the same prefab
GameObject instance1 = Instantiate(prefab, pos1, Quaternion.identity, parent);
GameObject instance2 = Instantiate(prefab, pos2, Quaternion.identity, parent);

// Cleanup: Release prefab when you no longer need more instances
// (existing instances are NOT destroyed)
Addressables.Release(loadHandle);

// B. InstantiateAsync — load + instantiate in one step
var instHandle = Addressables.InstantiateAsync(
    "Models/Model_001",
    position: Vector3.zero,
    rotation: Quaternion.identity,
    parent: modelContainer.transform
);
GameObject model = await instHandle.Task;

// Cleanup: ReleaseInstance destroys the object AND releases the asset
Addressables.ReleaseInstance(model);

// ═══════════════════════════════════════════════════════
// METHOD 2: AssetBundle — lower level, full control
// ═══════════════════════════════════════════════════════

// From local file (previously downloaded)
string bundlePath = Path.Combine(Application.persistentDataPath, "bundles/models");
AssetBundle bundle = await AssetBundle.LoadFromFileAsync(bundlePath);
GameObject prefab = bundle.LoadAsset<GameObject>("Model_001");
GameObject instance = Instantiate(prefab, Vector3.zero, Quaternion.identity);

// From URL (CDN)
var request = UnityWebRequestAssetBundle.GetAssetBundle(
    "https://cdn.example.com/bundles/models_android",
    version: 1,                     // cache version
    crc: 0                          // CRC check (0 = skip)
);
await request.SendWebRequest();
AssetBundle remoteBundle = DownloadHandlerAssetBundle.GetContent(request);
GameObject remotePrefab = remoteBundle.LoadAsset<GameObject>("Model_001");
Instantiate(remotePrefab);

// Cleanup
bundle.Unload(false); // false = do not destroy loaded assets in memory

// ═══════════════════════════════════════════════════════
// METHOD 3: Resources — NOT RECOMMENDED (but worth knowing)
// ═══════════════════════════════════════════════════════

// Files MUST be in the Assets/Resources/ folder
// All Resources are packed into the build — they increase APK size
GameObject prefab = Resources.Load<GameObject>("Models/Model_001");
Instantiate(prefab);

// Why not: everything from Resources goes into the build,
// no lazy loading, no remote, no cache.

// ═══════════════════════════════════════════════════════
// METHOD 4: glTF/GLB runtime — models from external sources
// ═══════════════════════════════════════════════════════

// Details in section 6 (glTF/GLB)
var gltf = new GltfImport();
await gltf.Load("https://api.example.com/models/model.glb");
gltf.InstantiateMainScene(modelContainer.transform);
```

### Full ModelManager Implementation (C#)

```csharp
/// <summary>
/// Manages loading, displaying, and removing models in the scene.
/// Inherits from FlutterMonoBehaviour — automatically listens for messages from Flutter.
/// </summary>
public class ModelManager : FlutterMonoBehaviour
{
    [SerializeField] private Transform modelContainer;
    [SerializeField] private Transform pedestalPosition;

    private GameObject _currentModel;
    private AsyncOperationHandle<GameObject> _currentHandle;
    private readonly Dictionary<string, AsyncOperationHandle<GameObject>> _preloadedModels = new();

    // ─── Flutter Message Handling ───
    protected override void OnFlutterMessage(string method, string data)
    {
        switch (method)
        {
            case "LoadModel":
                var loadPayload = JsonUtility.FromJson<ModelPayload>(data);
                _ = LoadModel(loadPayload.modelId, loadPayload.source, loadPayload.url);
                break;

            case "UnloadModel":
                UnloadCurrentModel();
                break;

            case "SwapModel":
                var swapPayload = JsonUtility.FromJson<ModelPayload>(data);
                _ = SwapModel(swapPayload.modelId, swapPayload.source, swapPayload.url);
                break;

            case "PreloadModel":
                var preloadPayload = JsonUtility.FromJson<ModelPayload>(data);
                _ = PreloadModel(preloadPayload.modelId);
                break;

            case "SetModelTransform":
                var transformData = JsonUtility.FromJson<ModelTransform>(data);
                ApplyTransform(transformData);
                break;

            case "SetModelAnimation":
                var animData = JsonUtility.FromJson<AnimPayload>(data);
                SetAnimation(animData.animationName, animData.speed);
                break;

            case "SetModelMaterial":
                var matData = JsonUtility.FromJson<MaterialPayload>(data);
                _ = SwapMaterial(matData.materialAddress);
                break;
        }
    }

    // ─── Core Loading ───
    private async Task LoadModel(string modelId, string source, string url = null)
    {
        UnloadCurrentModel();

        try
        {
            SendToFlutter("model_loading", JsonUtility.ToJson(new { modelId }));

            switch (source)
            {
                case "addressables":
                    // Check if preloaded
                    if (_preloadedModels.TryGetValue(modelId, out var preloaded))
                    {
                        _currentModel = Instantiate(
                            preloaded.Result,
                            pedestalPosition.position,
                            Quaternion.identity,
                            modelContainer
                        );
                        _preloadedModels.Remove(modelId);
                        _currentHandle = preloaded;
                    }
                    else
                    {
                        _currentHandle = Addressables.InstantiateAsync(
                            $"Models/{modelId}",
                            pedestalPosition.position,
                            Quaternion.identity,
                            modelContainer
                        );
                        _currentModel = await _currentHandle.Task;
                    }
                    break;

                case "gltf":
                    var gltf = new GltfImport();
                    bool success = await gltf.Load(url);
                    if (success)
                    {
                        gltf.InstantiateMainScene(modelContainer);
                        _currentModel = modelContainer.GetChild(modelContainer.childCount - 1).gameObject;
                        _currentModel.transform.position = pedestalPosition.position;
                    }
                    break;
            }

            SendToFlutter("model_loaded", JsonUtility.ToJson(new {
                modelId,
                success = _currentModel != null,
                bounds = GetBoundsJson(_currentModel)
            }));
        }
        catch (Exception e)
        {
            SendToFlutter("model_error", JsonUtility.ToJson(new {
                modelId,
                error = e.Message
            }));
        }
    }

    // ─── Swap (load new before removing old — no empty frame) ───
    private async Task SwapModel(string newModelId, string source, string url = null)
    {
        GameObject oldModel = _currentModel;

        // Load new (old is still visible)
        await LoadModel(newModelId, source, url);

        // Destroy old
        if (oldModel != null) Destroy(oldModel);
    }

    // ─── Preload (download to memory without instantiating) ───
    private async Task PreloadModel(string modelId)
    {
        if (_preloadedModels.ContainsKey(modelId)) return;

        var handle = Addressables.LoadAssetAsync<GameObject>($"Models/{modelId}");
        await handle.Task;
        _preloadedModels[modelId] = handle;

        SendToFlutter("model_preloaded", JsonUtility.ToJson(new { modelId }));
    }

    // ─── Unload ───
    private void UnloadCurrentModel()
    {
        if (_currentModel != null)
        {
            if (_currentHandle.IsValid())
                Addressables.ReleaseInstance(_currentModel);
            else
                Destroy(_currentModel);

            _currentModel = null;
        }
    }

    // ─── Transform / Animation / Material ───
    private void ApplyTransform(ModelTransform t)
    {
        if (_currentModel == null) return;
        _currentModel.transform.localPosition = new Vector3(t.x, t.y, t.z);
        _currentModel.transform.localEulerAngles = new Vector3(t.rx, t.ry, t.rz);
        _currentModel.transform.localScale = new Vector3(t.sx, t.sy, t.sz);
    }

    private void SetAnimation(string animName, float speed)
    {
        if (_currentModel == null) return;
        var animator = _currentModel.GetComponentInChildren<Animator>();
        if (animator == null) return;
        animator.speed = speed;
        animator.Play(animName);
    }

    private async Task SwapMaterial(string materialAddress)
    {
        if (_currentModel == null) return;
        var matHandle = Addressables.LoadAssetAsync<Material>(materialAddress);
        Material mat = await matHandle.Task;
        var renderers = _currentModel.GetComponentsInChildren<Renderer>();
        foreach (var r in renderers) r.material = mat;
    }

    // ─── Cleanup ───
    private void OnDestroy()
    {
        UnloadCurrentModel();
        foreach (var handle in _preloadedModels.Values)
            Addressables.Release(handle);
        _preloadedModels.Clear();
    }

    // ─── Helpers ───
    private string GetBoundsJson(GameObject obj)
    {
        if (obj == null) return "{}";
        var renderers = obj.GetComponentsInChildren<Renderer>();
        if (renderers.Length == 0) return "{}";
        Bounds bounds = renderers[0].bounds;
        for (int i = 1; i < renderers.Length; i++)
            bounds.Encapsulate(renderers[i].bounds);
        return JsonUtility.ToJson(new {
            centerX = bounds.center.x, centerY = bounds.center.y, centerZ = bounds.center.z,
            sizeX = bounds.size.x, sizeY = bounds.size.y, sizeZ = bounds.size.z
        });
    }
}

// ─── Payload structs ───
[Serializable] public struct ModelPayload { public string modelId; public string source; public string url; }
[Serializable] public struct ModelTransform { public float x, y, z, rx, ry, rz, sx, sy, sz; }
[Serializable] public struct AnimPayload { public string animationName; public float speed; }
[Serializable] public struct MaterialPayload { public string materialAddress; }
```

**Dart (Flutter -> Unity) — full API:**

```dart
// ═══════════════════════════════════════════════════════
// Flutter: full API for managing models
// ═══════════════════════════════════════════════════════

class ModelController {
  final UnityBridge _bridge;

  ModelController(this._bridge);

  // Load model from Addressables
  void loadModel(String modelId) {
    _bridge.send(UnityMessage.to('ModelManager', 'LoadModel', {
      'modelId': modelId,
      'source': 'addressables',
    }));
  }

  // Load model from URL (glTF)
  void loadModelFromUrl(String modelId, String glbUrl) {
    _bridge.send(UnityMessage.to('ModelManager', 'LoadModel', {
      'modelId': modelId,
      'source': 'gltf',
      'url': glbUrl,
    }));
  }

  // Preload (download to cache without displaying)
  void preloadModel(String modelId) {
    _bridge.send(UnityMessage.to('ModelManager', 'PreloadModel', {
      'modelId': modelId,
    }));
  }

  // Swap model for another (smooth swap)
  void swapModel(String newModelId) {
    _bridge.send(UnityMessage.to('ModelManager', 'SwapModel', {
      'modelId': newModelId,
      'source': 'addressables',
    }));
  }

  // Remove current model
  void unloadModel() {
    _bridge.send(UnityMessage.command('UnloadModel', {}));
  }

  // Set position/rotation/scale
  void setTransform({
    double x = 0, double y = 0, double z = 0,
    double rx = 0, double ry = 0, double rz = 0,
    double sx = 1, double sy = 1, double sz = 1,
  }) {
    _bridge.send(UnityMessage.to('ModelManager', 'SetModelTransform', {
      'x': x, 'y': y, 'z': z,
      'rx': rx, 'ry': ry, 'rz': rz,
      'sx': sx, 'sy': sy, 'sz': sz,
    }));
  }

  // Set animation
  void setAnimation(String name, {double speed = 1.0}) {
    _bridge.send(UnityMessage.to('ModelManager', 'SetModelAnimation', {
      'animationName': name,
      'speed': speed,
    }));
  }

  // Change material
  void setMaterial(String materialAddress) {
    _bridge.send(UnityMessage.to('ModelManager', 'SetModelMaterial', {
      'materialAddress': materialAddress,
    }));
  }

  // Event streams
  Stream<Map<String, dynamic>> get onModelLoaded =>
      _bridge.messageStream
          .where((msg) => msg.type == 'model_loaded')
          .map((msg) => msg.data ?? {});

  Stream<Map<String, dynamic>> get onModelLoading =>
      _bridge.messageStream
          .where((msg) => msg.type == 'model_loading')
          .map((msg) => msg.data ?? {});

  Stream<Map<String, dynamic>> get onModelError =>
      _bridge.messageStream
          .where((msg) => msg.type == 'model_error')
          .map((msg) => msg.data ?? {});
}
```

### Usage Scenarios — In Detail

| Scenario | Method | Source | Details |
|----------|--------|--------|---------|
| Single model preview | `LoadModel` | Addressables | Load into scene with pedestal, orbit camera, lighting |
| Collection (grid) | Loop `InstantiateAsync` | Addressables | Load thumbnails (LOD 2) on grid. Full model only after tap |
| Swipe carousel | `SwapModel` | Addressables | Preload next/previous. Swap without empty frame |
| NFT from marketplace | `LoadModel(gltf)` | glTF from URL | Model comes as .glb from API. No prefab in Unity |
| Customization | `SetMaterial` | Addressables | Load material variant. Swap on renderer |
| Seasonal skin | `SetMaterial` | Remote Config + Addressables | RC specifies material address -> load from Addressables |
| Gallery collection | Loop load + `RenderTexture` | Addressables | Render model to texture -> show as thumbnail in UI |

### Object Pooling — Optimization for Collections

```csharp
/// <summary>
/// Object pool — recycle instead of Destroy/Instantiate.
/// Critical for collections with scrolling (carousel, grid).
/// </summary>
public class ModelPool
{
    private readonly Dictionary<string, Queue<GameObject>> _pools = new();
    private readonly Transform _poolRoot;

    public ModelPool(Transform poolRoot)
    {
        _poolRoot = poolRoot;
        _poolRoot.gameObject.SetActive(false); // Hide pooled objects
    }

    public async Task<GameObject> Get(string modelId, Transform parent)
    {
        if (_pools.TryGetValue(modelId, out var queue) && queue.Count > 0)
        {
            // Recycle from pool
            var obj = queue.Dequeue();
            obj.transform.SetParent(parent);
            obj.SetActive(true);
            return obj;
        }

        // Not in pool — load new
        var handle = Addressables.InstantiateAsync($"Models/{modelId}", parent);
        return await handle.Task;
    }

    public void Return(string modelId, GameObject obj)
    {
        obj.SetActive(false);
        obj.transform.SetParent(_poolRoot);

        if (!_pools.ContainsKey(modelId))
            _pools[modelId] = new Queue<GameObject>();

        _pools[modelId].Enqueue(obj);
    }

    public void Clear()
    {
        foreach (var queue in _pools.Values)
            while (queue.Count > 0)
                Addressables.ReleaseInstance(queue.Dequeue());
        _pools.Clear();
    }
}
```

### Shader Warmup — Eliminating Stutter

```csharp
/// <summary>
/// Shader warmup — precompile shader variants at startup.
/// Without this: the first render of a new shader = 50-200ms stutter.
/// </summary>
public class ShaderWarmup : MonoBehaviour
{
    [SerializeField] private ShaderVariantCollection shaderVariants;

    private void Start()
    {
        // Precompile ALL variants declared in the collection
        if (shaderVariants != null)
        {
            shaderVariants.WarmUp();
            Debug.Log($"Warmed up {shaderVariants.shaderCount} shaders, " +
                      $"{shaderVariants.variantCount} variants");
        }
    }
}

// How to create a ShaderVariantCollection:
// 1. Window > Analysis > Shader Variant Tracker (Unity 6000+)
// 2. Or manually: Create > Shader > Shader Variant Collection
// 3. Add shaders + variants used by model prefabs
// 4. Assign to ShaderWarmup component in the Core scene
```

### Texture Compression — Impact on Memory

| Format | iOS | Android | Quality | Size | GPU Decompression |
|--------|:---:|:-------:|---------|------|:-:|
| **ASTC 4x4** | Yes | Yes | Best | Medium | Yes |
| **ASTC 6x6** | Yes | Yes | Good | Small | Yes |
| **ASTC 8x8** | Yes | Yes | Acceptable | Very small | Yes |
| **ETC2** | No | Yes | Good | Small | Yes |
| **PVRTC** | Yes (legacy) | No | Acceptable | Small | Yes |
| **RGB24 (uncompressed)** | Yes | Yes | Perfect | HUGE | No |

**Recommendation:** ASTC 6x6 as default. ASTC 4x4 for face details/close-ups. ASTC 8x8 for terrains/backgrounds.

```
Example: 2048x2048 texture
├── RGB24:   12 MB in VRAM
├── ASTC 4x4: 1 MB in VRAM  (12x smaller!)
├── ASTC 6x6: 0.5 MB in VRAM
└── ASTC 8x8: 0.25 MB in VRAM

For a collection of 50 models with 3 textures each (diffuse, normal, mask):
├── RGB24:   50 x 3 x 12 MB = 1800 MB  ← will not fit in RAM
├── ASTC 4x4: 50 x 3 x 1 MB = 150 MB   ← OK on mid-range
└── ASTC 6x6: 50 x 3 x 0.5 MB = 75 MB  ← OK even on low-end
```

---

## 4. AssetBundles

### What Is It?

Archives of platform-specific assets (models, textures, materials, prefabs, scenes) loaded at runtime. This is a **low-level** system — the foundation on which Addressables is built. Each bundle is a binary file containing serialized Unity assets in the native format for a given platform.

**When to use raw AssetBundles instead of Addressables?**
- When you need full control over packing, versioning, and caching
- When you have an existing pipeline/CDN and do not want Unity abstraction dependencies
- When the project is migrating from a legacy system
- In most cases: **use Addressables** (section 5), which manage AssetBundles automatically

### How Does It Work? — Complete Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│                        BUILD TIME                             │
│                                                               │
│  1. Mark assets in Inspector → AssetBundle name               │
│     e.g. "models/common", "models/rare", "scenes/showroom"   │
│                                                               │
│  2. Build script generates bundles:                           │
│     BuildPipeline.BuildAssetBundles(                          │
│         outputPath,                                           │
│         BuildAssetBundleOptions.ChunkBasedCompression,        │
│         BuildTarget.Android  // OR BuildTarget.iOS            │
│     );                                                        │
│                                                               │
│  3. Output:                                                   │
│     outputPath/                                               │
│     ├── models_common              (bundle file)              │
│     ├── models_common.manifest     (dependencies, hash)       │
│     ├── models_rare                                           │
│     ├── models_rare.manifest                                  │
│     ├── scenes_showroom                                       │
│     ├── scenes_showroom.manifest                              │
│     └── Android                    (master manifest)          │
│                                                               │
│  IMPORTANT: A bundle built for Android does NOT work on iOS!  │
│  You must build separately per platform.                      │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│                    HOSTING / DISTRIBUTION                      │
│                                                               │
│  Option A: CDN (S3, CloudFront, Cloudflare R2, GCS)          │
│  ├── https://cdn.example.com/bundles/android/v42/models_common│
│  └── https://cdn.example.com/bundles/ios/v42/models_common   │
│                                                               │
│  Option B: Unity CCD (Cloud Content Delivery)                │
│  ├── Dashboard → Bucket "android-prod" → Upload              │
│  └── Dashboard → Bucket "ios-prod" → Upload                  │
│                                                               │
│  Option C: StreamingAssets (built into APK/IPA)              │
│  └── Assets/StreamingAssets/bundles/models_common             │
│                                                               │
│  Option D: Google Play Asset Delivery (Android only)         │
│  ├── install-time: downloaded with APK (at installation)      │
│  ├── fast-follow: downloaded right after installation         │
│  └── on-demand: downloaded on user request                    │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│                         RUNTIME                               │
│                                                               │
│  1. Download/load bundle                                     │
│  2. Load asset from bundle (prefab, texture, scene...)       │
│  3. Instantiate in scene                                     │
│  4. When no longer needed → Unload bundle                    │
│  5. When asset not needed → Destroy + UnloadUnusedAssets     │
└──────────────────────────────────────────────────────────────┘
```

### Complete Code Examples

```csharp
// ═══════════════════════════════════════════════════════
// 1. LOADING FROM LOCAL FILE (StreamingAssets or downloaded)
// ═══════════════════════════════════════════════════════

// A. From StreamingAssets (built into APK/IPA)
IEnumerator LoadFromStreamingAssets()
{
    // On Android: StreamingAssets is in JAR (compressed) → requires UnityWebRequest
    // On iOS: StreamingAssets is a normal folder → can use LoadFromFile
    string path;

    #if UNITY_ANDROID && !UNITY_EDITOR
        path = Application.streamingAssetsPath + "/bundles/models_common";
        var request = UnityWebRequestAssetBundle.GetAssetBundle(path);
        yield return request.SendWebRequest();
        AssetBundle bundle = DownloadHandlerAssetBundle.GetContent(request);
    #else
        path = Path.Combine(Application.streamingAssetsPath, "bundles/models_common");
        var bundleRequest = AssetBundle.LoadFromFileAsync(path);
        yield return bundleRequest;
        AssetBundle bundle = bundleRequest.assetBundle;
    #endif

    if (bundle == null) { Debug.LogError("Failed to load bundle"); yield break; }

    // Load prefab from bundle
    var assetRequest = bundle.LoadAssetAsync<GameObject>("Model_001");
    yield return assetRequest;
    Instantiate((GameObject)assetRequest.asset);
}

// B. From Application.persistentDataPath (previously downloaded)
IEnumerator LoadFromDownloaded()
{
    string path = Path.Combine(Application.persistentDataPath, "bundles/models_common");

    if (!File.Exists(path))
    {
        Debug.LogError($"Bundle not found: {path}");
        yield break;
    }

    var bundleRequest = AssetBundle.LoadFromFileAsync(path);
    yield return bundleRequest;
    AssetBundle bundle = bundleRequest.assetBundle;

    // Load ALL prefabs from the bundle
    var allAssets = bundle.LoadAllAssetsAsync<GameObject>();
    yield return allAssets;

    foreach (var asset in allAssets.allAssets)
    {
        Debug.Log($"Found prefab in bundle: {asset.name}");
    }
}

// ═══════════════════════════════════════════════════════
// 2. DOWNLOADING FROM SERVER (CDN)
// ═══════════════════════════════════════════════════════

IEnumerator DownloadAndLoadBundle(string url, uint version)
{
    // UnityWebRequestAssetBundle automatically caches!
    // version = version number. Same version → cache hit.
    // Version change → new download.
    var request = UnityWebRequestAssetBundle.GetAssetBundle(url, version, crc: 0);

    // Progress tracking
    request.SendWebRequest();
    while (!request.isDone)
    {
        float progress = request.downloadProgress;
        NativeAPI.SendToFlutter(JsonUtility.ToJson(new {
            type = "bundle_download_progress",
            url = url,
            progress = progress
        }));
        yield return null;
    }

    if (request.result != UnityWebRequest.Result.Success)
    {
        Debug.LogError($"Download failed: {request.error}");
        yield break;
    }

    AssetBundle bundle = DownloadHandlerAssetBundle.GetContent(request);
    // ... use the bundle
}

// ═══════════════════════════════════════════════════════
// 3. DEPENDENCY MANAGEMENT (manual!)
// ═══════════════════════════════════════════════════════

// Problem: models_rare prefab uses a material from shared_materials bundle.
// If shared_materials is not loaded → missing material (magenta).

IEnumerator LoadWithDependencies(string bundleName)
{
    // 1. Load master manifest (contains dependency info)
    var masterRequest = AssetBundle.LoadFromFileAsync(
        Path.Combine(Application.persistentDataPath, "bundles/Android")
    );
    yield return masterRequest;
    AssetBundleManifest manifest = masterRequest.assetBundle
        .LoadAsset<AssetBundleManifest>("AssetBundleManifest");

    // 2. Get list of dependencies
    string[] dependencies = manifest.GetAllDependencies(bundleName);
    // e.g. ["shared_materials", "shared_textures"]

    // 3. Load ALL dependencies BEFORE the main bundle
    List<AssetBundle> depBundles = new();
    foreach (string dep in dependencies)
    {
        var depRequest = AssetBundle.LoadFromFileAsync(
            Path.Combine(Application.persistentDataPath, $"bundles/{dep}")
        );
        yield return depRequest;
        depBundles.Add(depRequest.assetBundle);
    }

    // 4. Only now load the main bundle
    var mainRequest = AssetBundle.LoadFromFileAsync(
        Path.Combine(Application.persistentDataPath, $"bundles/{bundleName}")
    );
    yield return mainRequest;

    // 5. Now assets from the main bundle have access to dependencies
    var prefab = mainRequest.assetBundle.LoadAsset<GameObject>("Model_001");
    Instantiate(prefab); // Materials loaded correctly!
}

// ═══════════════════════════════════════════════════════
// 4. UNLOAD — critical on mobile
// ═══════════════════════════════════════════════════════

// Unload(false): release ONLY the bundle from memory.
// Loaded assets (prefabs, textures) REMAIN in memory.
// You can no longer load new assets from this bundle.
bundle.Unload(false);

// Unload(true): release bundle + ALL loaded assets.
// Instances in the scene lose materials/textures (magenta).
// Use ONLY when you know nothing from this bundle is in the scene.
bundle.Unload(true);

// Cleanup orphaned assets (after Unload(false) + Destroy instances)
yield return Resources.UnloadUnusedAssets();
System.GC.Collect();
```

### Bundle Compression

| Option | Size on Disk | Load Time | RAM During Loading | Usage |
|--------|:-:|:-:|:-:|---------|
| **Uncompressed** | Large | Fastest | Low | Dev/debug |
| **LZMA** | Smallest | Slow (full decompression) | High peak | Download (then re-compress to LZ4) |
| **LZ4 (ChunkBased)** | Medium | Fast (chunk-by-chunk) | Low | **RECOMMENDED on mobile** |

```csharp
// Recommended build:
BuildPipeline.BuildAssetBundles(
    outputPath,
    BuildAssetBundleOptions.ChunkBasedCompression, // LZ4
    BuildTarget.Android
);
```

### Packing Strategies — What to Pack Together?

| Strategy | Description | When to Use |
|----------|-------------|-------------|
| **Per-asset** | One prefab = one bundle | When models are loaded individually, independently |
| **Per-group** | Group of models = one bundle (e.g. "common", "rare") | When models of a given group are loaded together |
| **Shared dependencies** | Shared materials/textures in a separate bundle | When many models share materials |
| **Per-scene** | Entire scene + its assets = one bundle | For additive scene loading from server |

```
Recommended bundle structure:
├── shared_materials    (materials used by many models)
├── shared_textures     (shared textures, e.g. particle atlas)
├── shared_shaders      (custom shaders)
├── models_common_01    (common tier models, batch 1: 10 models)
├── models_common_02    (common tier models, batch 2: 10 models)
├── models_rare_01      (rare tier models)
├── models_legendary_01 (legendary tier models)
├── scenes_showroom     (model preview scene)
├── scenes_collection   (collection scene)
└── scenes_ar           (AR scene)
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Full control over packing and strategy | Manual dependency management — EVERY one must be tracked |
| Any CDN/server — no vendor lock-in | Manual versioning, hash checking, cache invalidation |
| Mature system (10+ years in production) | Bundle per platform (iOS != Android) — double build |
| Supports delta patching (changed bundles) | No built-in reference counting — memory leaks are easy |
| Can host scenes, prefabs, audio, everything | Complicated variants/naming at large scale |
| LZ4 compression = fast loading on mobile | Manifest must be manually parsed for dependencies |
| Full control over cache (version, CRC) | Debugging issues (missing dependencies) is difficult |

### Platform Notes

**Android:**
- `StreamingAssets` is packed inside the APK (in the `/assets/` folder of JAR) — it is compressed and you **cannot** use `AssetBundle.LoadFromFile()`. Requires `UnityWebRequest` or `BetterStreamingAssets` (asset store).
- **Google Play Asset Delivery (PAD)**: For apps >150MB. Bundles can be delivered as:
  - `install-time`: packed with APK, available immediately
  - `fast-follow`: downloaded automatically after installation
  - `on-demand`: downloaded when the user needs them (ideal for models)
- Scoped Storage (Android 11+): save downloaded bundles to `Application.persistentDataPath` — the only place without permissions.

**iOS:**
- StreamingAssets is a normal folder in the app bundle — `LoadFromFile()` works.
- Save downloaded bundles to `Application.persistentDataPath`.
- **Cellular download limit**: ~200MB. Apple blocks downloads >200MB on LTE. Make sure bundles per model are <10MB, or inform the user about the need for Wi-Fi.
- **Background download**: iOS does not allow Unity to download in the background. Use native `NSURLSession` with background configuration (requires native plugin).
- **App Thinning**: Bundles in StreamingAssets are NOT subject to App Thinning (iOS does not know what is in them). Size is 1:1.

---

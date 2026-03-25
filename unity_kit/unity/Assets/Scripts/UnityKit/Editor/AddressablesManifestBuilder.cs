#if ADDRESSABLES_INSTALLED
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using UnityEditor;
using UnityEditor.AddressableAssets;
using UnityEditor.AddressableAssets.Build;
using UnityEditor.AddressableAssets.Settings;
using UnityEngine;

namespace UnityKit.Editor
{
    /// <summary>
    /// Editor tool to build Addressables content and generate a
    /// <c>content_manifest.json</c> compatible with <c>unity_kit</c> streaming.
    ///
    /// <para>
    /// Access via the Unity menu: <b>Flutter > Build Addressables</b>.
    /// Requires the <c>com.unity.addressables</c> package and the
    /// <c>ADDRESSABLES_INSTALLED</c> scripting define symbol.
    /// </para>
    /// </summary>
    public static class AddressablesManifestBuilder
    {
        private const string MANIFEST_NAME = "content_manifest.json";

        [MenuItem("Flutter/Build Addressables")]
        public static void BuildAddressables()
        {
            var settings = AddressableAssetSettingsDefaultObject.Settings;
            if (settings == null)
            {
                Debug.LogError("[UnityKit] Addressable Asset Settings not found. Configure Addressables first.");
                return;
            }

            AddressableAssetSettings.CleanPlayerContent(
                AddressableAssetSettingsDefaultObject.Settings.ActivePlayerDataBuilder
            );

            AddressableAssetSettings.BuildPlayerContent(out AddressablesPlayerBuildResult result);

            if (!string.IsNullOrEmpty(result.Error))
            {
                Debug.LogError($"[UnityKit] Addressables build failed: {result.Error}");
                return;
            }

            Debug.Log($"[UnityKit] Addressables built successfully. Output: {settings.RemoteCatalogBuildPath.GetValue(settings)}");

            GenerateManifest(settings, result);
        }

        private static void GenerateManifest(AddressableAssetSettings settings, AddressablesPlayerBuildResult result)
        {
            var remoteBuildPath = settings.RemoteCatalogBuildPath.GetValue(settings);
            var remoteLoadPath = settings.RemoteCatalogLoadPath.GetValue(settings);

            if (!Directory.Exists(remoteBuildPath))
            {
                Debug.LogWarning($"[UnityKit] Remote build path does not exist: {remoteBuildPath}");
                return;
            }

            // Find the catalog .bin file for dynamic catalog loading
            var catalogFiles = Directory.GetFiles(remoteBuildPath, "catalog_*.bin");
            string catalogUrl = null;
            if (catalogFiles.Length > 0)
            {
                var catalogName = Path.GetFileName(catalogFiles[0]);
                catalogUrl = $"{remoteLoadPath}/{catalogName}";
                Debug.Log($"[UnityKit] Found catalog for dynamic loading: {catalogName}");
            }
            else
            {
                Debug.LogWarning("[UnityKit] No catalog .bin file found. Unity will use embedded catalog.");
            }

            // Build a mapping from bundle filename to Addressable addresses.
            var bundleToKeys = BuildBundleToKeysMap(settings);

            var bundleFiles = Directory.GetFiles(remoteBuildPath, "*.bundle");
            var bundlesJson = new System.Text.StringBuilder();
            bundlesJson.Append("[");

            for (var i = 0; i < bundleFiles.Length; i++)
            {
                var bundlePath = bundleFiles[i];
                var bundleName = Path.GetFileName(bundlePath);
                var fileInfo = new FileInfo(bundlePath);
                var sha256 = ComputeSha256(bundlePath);

                if (i > 0) bundlesJson.Append(",");
                bundlesJson.Append("\n    {");
                bundlesJson.Append($"\n      \"name\": \"{bundleName}\",");
                bundlesJson.Append($"\n      \"url\": \"{remoteLoadPath}/{bundleName}\",");
                bundlesJson.Append($"\n      \"sizeBytes\": {fileInfo.Length},");
                bundlesJson.Append($"\n      \"sha256\": \"{sha256}\",");
                bundlesJson.Append("\n      \"isBase\": false,");
                bundlesJson.Append("\n      \"dependencies\": [],");
                bundlesJson.Append($"\n      \"group\": \"addressables\",");

                if (bundleToKeys.TryGetValue(bundleName, out var keys) && keys.Count > 0)
                {
                    var keysJson = string.Join(", ", keys.ConvertAll(k => $"\"{k}\""));
                    bundlesJson.Append($"\n      \"metadata\": {{\"addressableKeys\": [{keysJson}]}}");
                }
                else
                {
                    bundlesJson.Append("\n      \"metadata\": {}");
                }

                bundlesJson.Append("\n    }");
            }

            bundlesJson.Append("\n  ]");

            var catalogLine = catalogUrl != null
                ? $"  \"catalogUrl\": \"{catalogUrl}\",\n"
                : "";

            var manifestJson = "{\n"
                + $"  \"version\": \"1.0.0\",\n"
                + $"  \"baseUrl\": \"{remoteLoadPath}\",\n"
                + catalogLine
                + $"  \"bundles\": {bundlesJson},\n"
                + $"  \"buildTime\": \"{System.DateTime.UtcNow:O}\",\n"
                + $"  \"platform\": \"{EditorUserBuildSettings.activeBuildTarget}\"\n"
                + "}";

            var manifestPath = Path.Combine(remoteBuildPath, MANIFEST_NAME);
            File.WriteAllText(manifestPath, manifestJson);

            Debug.Log($"[UnityKit] Addressables manifest generated: {manifestPath}");
        }

        /// <summary>
        /// Builds a map from bundle filename to the Addressable addresses it contains.
        ///
        /// For "Pack Separately" groups each bundle contains exactly one entry.
        /// Matching works by checking whether the bundle filename (lowercased,
        /// minus hash and extension) contains the entry's address.
        /// </summary>
        private static Dictionary<string, List<string>> BuildBundleToKeysMap(AddressableAssetSettings settings)
        {
            // Collect all addressable entries.
            var allEntries = new List<(string address, string groupName)>();

            foreach (var group in settings.groups)
            {
                if (group == null) continue;

                foreach (var entry in group.entries)
                {
                    allEntries.Add((entry.address, group.Name));
                }
            }

            // Get all built bundle files from the remote build path.
            var remoteBuildPath = settings.RemoteCatalogBuildPath.GetValue(settings);
            if (!Directory.Exists(remoteBuildPath))
                return new Dictionary<string, List<string>>();

            var bundleFiles = Directory.GetFiles(remoteBuildPath, "*.bundle");
            var map = new Dictionary<string, List<string>>();

            foreach (var bundleFile in bundleFiles)
            {
                var bundleName = Path.GetFileName(bundleFile);
                // Strip .bundle extension and the 32-char content hash suffix.
                // E.g. "toys_assets_alphie_toonshader_7a4fc9b8396a7087b05f73c11d2251e0.bundle"
                // -> "toys_assets_alphie_toonshader"
                var nameWithoutExt = Path.GetFileNameWithoutExtension(bundleName);
                var bundlePrefix = StripContentHash(nameWithoutExt);

                var keys = new List<string>();

                foreach (var (address, groupName) in allEntries)
                {
                    // Check if the bundle prefix contains the address.
                    // This works for Pack Separately where bundle name embeds the asset address.
                    if (bundlePrefix.Contains(address.ToLowerInvariant()))
                    {
                        keys.Add(address);
                    }
                }

                if (keys.Count > 0)
                {
                    map[bundleName] = keys;
                    Debug.Log($"[UnityKit] Bundle '{bundleName}' -> keys: [{string.Join(", ", keys)}]");
                }
            }

            return map;
        }

        /// <summary>
        /// Strips the 32-character content hash suffix from a bundle name.
        /// E.g. "toys_assets_alphie_toonshader_7a4fc9b8396a7087b05f73c11d2251e0"
        /// -> "toys_assets_alphie_toonshader"
        /// </summary>
        private static string StripContentHash(string name)
        {
            var lastUnderscore = name.LastIndexOf('_');
            if (lastUnderscore < 0) return name;

            var suffix = name.Substring(lastUnderscore + 1);
            // Content hash is 32 hex characters.
            if (suffix.Length == 32 && IsHexString(suffix))
            {
                return name.Substring(0, lastUnderscore);
            }

            return name;
        }

        private static bool IsHexString(string s)
        {
            foreach (var c in s)
            {
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
                    return false;
            }
            return true;
        }

        private static string ComputeSha256(string filePath)
        {
            using (var sha256 = SHA256.Create())
            using (var stream = File.OpenRead(filePath))
            {
                var hash = sha256.ComputeHash(stream);
                return System.BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }
        }
    }
}
#endif

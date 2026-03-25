using System;
using UnityEngine;

namespace UnityKit
{
    /// <summary>
    /// Main bridge between Flutter and Unity.
    /// Singleton MonoBehaviour that receives messages from Flutter
    /// and routes them to registered handlers.
    ///
    /// Auto-creates at runtime if no FlutterBridge exists in the scene,
    /// so there is no need to manually add it to the scene hierarchy.
    /// </summary>
    public class FlutterBridge : MonoBehaviour
    {
        public static FlutterBridge Instance { get; private set; }

        /// <summary>
        /// Event fired when any message is received from Flutter.
        /// Parameters: target, method, data.
        /// </summary>
        public event Action<string, string, string> OnFlutterMessage;

        /// <summary>
        /// Event fired when a typed message (with "type" field) is received.
        /// Parameters: type, rawJson.
        /// Used by unity_kit Flutter bridge which sends {"type":"...", "data":{...}}.
        /// </summary>
        public event Action<string, string> OnTypedMessage;

        /// <summary>
        /// Event fired when the bridge is ready.
        /// </summary>
        public event Action OnReady;

        [SerializeField] private bool sendReadyOnStart = true;

        /// <summary>
        /// Auto-creates FlutterBridge if not present in the scene.
        /// Runs before scene objects are loaded.
        /// </summary>
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        private static void AutoCreate()
        {
            if (Instance != null) return;

            var go = new GameObject("FlutterBridge");
            go.AddComponent<FlutterBridge>();
            UnityKitLogger.Info("FlutterBridge auto-created");
        }

        void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Destroy(gameObject);
                return;
            }
            Instance = this;
            DontDestroyOnLoad(gameObject);
        }

        void Start()
        {
            if (sendReadyOnStart)
            {
                SendReady();
            }
        }

        /// <summary>
        /// Send ready signal to Flutter.
        /// </summary>
        public void SendReady()
        {
            NativeAPI.SendToFlutter("{\"type\":\"ready\"}");
            OnReady?.Invoke();
        }

        /// <summary>
        /// Called by Flutter via UnitySendMessage.
        /// Entry point for all incoming messages.
        ///
        /// Supports two formats:
        /// 1. Typed: {"type":"SetParameter","data":{"param":"x","value":1.0}} (unity_kit)
        /// 2. Routed: {"target":"handler","method":"DoThing","data":"payload"} (legacy)
        /// </summary>
        public void ReceiveMessage(string json)
        {
            if (string.IsNullOrEmpty(json)) return;

            try
            {
                // Handle batch messages
                if (json.TrimStart().StartsWith("["))
                {
                    HandleBatch(json);
                    return;
                }

                // Try typed format first (unity_kit sends {"type":"...", "data":{...}})
                var typed = JsonUtility.FromJson<TypedMessage>(json);
                if (!string.IsNullOrEmpty(typed?.type))
                {
                    OnTypedMessage?.Invoke(typed.type, json);
                    OnFlutterMessage?.Invoke(typed.type, string.Empty, json);
                    return;
                }

                // Fallback: routed format {"target":"...", "method":"...", "data":"..."}
                var msg = JsonUtility.FromJson<FlutterMessage>(json);
                if (msg == null) return;

                MessageRouter.Route(
                    msg.target ?? string.Empty,
                    msg.method ?? string.Empty,
                    msg.data ?? string.Empty
                );
                OnFlutterMessage?.Invoke(
                    msg.target ?? string.Empty,
                    msg.method ?? string.Empty,
                    msg.data ?? string.Empty
                );
            }
            catch (Exception e)
            {
                UnityKitLogger.Error($"Failed to parse message: {e.Message}\nJSON: {json}");
            }
        }

        private void HandleBatch(string batchJson)
        {
            var content = batchJson.Trim().TrimStart('[').TrimEnd(']');
            if (string.IsNullOrEmpty(content)) return;

            var depth = 0;
            var start = 0;
            for (var i = 0; i < content.Length; i++)
            {
                if (content[i] == '{') depth++;
                else if (content[i] == '}') depth--;

                if (depth == 0 && i > start)
                {
                    var msgJson = content.Substring(start, i - start + 1).Trim();
                    if (msgJson.Length > 0)
                    {
                        ReceiveMessage(msgJson);
                    }
                    start = i + 1;
                    while (start < content.Length && (content[start] == ',' || content[start] == ' '))
                        start++;
                }
            }
        }

        /// <summary>
        /// Called by Flutter via UnitySendMessage to set Application.targetFrameRate.
        /// Accepts a string representation of the frame rate (e.g., "60").
        /// </summary>
        public void SetTargetFrameRate(string frameRateStr)
        {
            if (int.TryParse(frameRateStr, out var frameRate) && frameRate > 0)
            {
                Application.targetFrameRate = frameRate;
                UnityKitLogger.Info($"Target frame rate set to {frameRate}");
            }
        }

        void OnDestroy()
        {
            if (Instance == this)
            {
                Instance = null;
            }
        }

        /// <summary>
        /// Internal class for detecting typed messages.
        /// </summary>
        [Serializable]
        private class TypedMessage
        {
            public string type;
        }
    }
}

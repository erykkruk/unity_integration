using System;
using UnityEngine;

namespace UnityKit
{
    /// <summary>
    /// Generic logger for UnityKit scripts.
    ///
    /// Defaults to Unity's <c>Debug.Log</c> with a <c>[UnityKit]</c> prefix.
    /// Projects can redirect output by assigning custom delegates:
    /// <code>
    /// UnityKitLogger.LogAction = msg => MyLogger.Info(msg);
    /// UnityKitLogger.WarnAction = msg => MyLogger.Warn(msg);
    /// UnityKitLogger.ErrorAction = msg => MyLogger.Error(msg);
    /// </code>
    /// </summary>
    public static class UnityKitLogger
    {
        public static Action<string> LogAction = msg => Debug.Log($"[UnityKit] {msg}");
        public static Action<string> WarnAction = msg => Debug.LogWarning($"[UnityKit] {msg}");
        public static Action<string> ErrorAction = msg => Debug.LogError($"[UnityKit] {msg}");

        public static void Info(string message) => LogAction(message);
        public static void Warning(string message) => WarnAction(message);
        public static void Error(string message) => ErrorAction(message);
    }
}

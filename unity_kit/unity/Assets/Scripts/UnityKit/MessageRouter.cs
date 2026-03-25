using System;
using System.Collections.Generic;

namespace UnityKit
{
    /// <summary>
    /// Routes incoming Flutter messages to registered handlers by target name.
    /// </summary>
    public static class MessageRouter
    {
        private static readonly Dictionary<string, Action<string, string>> _handlers = new();

        public static void Register(string target, Action<string, string> handler)
        {
            _handlers[target] = handler;
        }

        public static void Unregister(string target)
        {
            _handlers.Remove(target);
        }

        public static void Route(string target, string method, string data)
        {
            if (_handlers.TryGetValue(target, out var handler))
            {
                handler(method, data);
            }
            else
            {
                UnityKitLogger.Warning($"No handler registered for target: {target}");
            }
        }

        public static bool HasHandler(string target)
        {
            return _handlers.ContainsKey(target);
        }

        public static void Clear()
        {
            _handlers.Clear();
        }
    }
}

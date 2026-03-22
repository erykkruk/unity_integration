import 'dart:convert';

/// A typed message exchanged between Flutter and Unity.
///
/// Example:
/// ```dart
/// // Command to Unity
/// final msg = UnityMessage.command('LoadScene', {'name': 'Level1'});
///
/// // Event from Unity
/// final event = UnityMessage.fromJson('{"type":"scene_loaded","data":"Level1"}');
/// ```
class UnityMessage {
  /// Creates a new [UnityMessage].
  const UnityMessage({
    required this.type,
    this.data,
    this.gameObject = 'FlutterBridge',
    this.method = 'ReceiveMessage',
  });

  /// Creates a command message to send to Unity.
  factory UnityMessage.command(String action, [Map<String, dynamic>? data]) {
    return UnityMessage(
      type: action,
      data: data,
    );
  }

  /// Creates a message targeting a specific Unity GameObject and method.
  factory UnityMessage.to(
    String gameObject,
    String method, [
    Map<String, dynamic>? data,
  ]) {
    return UnityMessage(
      type: method,
      data: data,
      gameObject: gameObject,
      method: method,
    );
  }

  /// Creates a routed message that goes through FlutterBridge's MessageRouter.
  ///
  /// Instead of targeting a GameObject directly via UnitySendMessage,
  /// this sends to FlutterBridge.ReceiveMessage() with a JSON payload
  /// containing `target`, `method`, and `data` fields. FlutterBridge
  /// then routes the message to the registered handler.
  ///
  /// Use this for C# managers that register with [MessageRouter] instead
  /// of being standalone GameObjects (e.g. FlutterAddressablesManager).
  factory UnityMessage.routed(
    String target,
    String method, [
    Map<String, dynamic>? data,
  ]) {
    return _RoutedUnityMessage(
      target: target,
      routedMethod: method,
      routedData: data != null ? json.encode(data) : '',
    );
  }

  /// Parses a JSON string received from Unity.
  ///
  /// Throws [FormatException] if [jsonString] is not valid JSON or
  /// does not contain a 'type' field.
  factory UnityMessage.fromJson(String jsonString) {
    final decoded = json.decode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Expected a JSON object, got ${decoded.runtimeType}',
        jsonString,
      );
    }

    final type = decoded['type'];
    if (type is! String) {
      throw FormatException(
        'Missing or invalid "type" field in Unity message',
        jsonString,
      );
    }

    final rawData = decoded['data'];
    final Map<String, dynamic>? data;
    if (rawData is Map<String, dynamic>) {
      data = rawData;
    } else if (rawData != null) {
      data = {'value': rawData};
    } else {
      data = null;
    }

    return UnityMessage(
      type: type,
      data: data,
    );
  }

  /// Message type identifier (e.g., 'LoadScene', 'scene_loaded').
  final String type;

  /// Optional payload data.
  final Map<String, dynamic>? data;

  /// Target Unity GameObject name.
  final String gameObject;

  /// Target method name on the GameObject.
  final String method;

  /// Serializes this message to a JSON string for sending to Unity.
  String toJson() {
    return json.encode({
      'type': type,
      if (data != null) 'data': data,
    });
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnityMessage &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          gameObject == other.gameObject &&
          method == other.method;

  @override
  int get hashCode => Object.hash(type, gameObject, method);

  @override
  String toString() => 'UnityMessage(type: $type, data: $data)';
}

/// A message routed through FlutterBridge's MessageRouter.
///
/// Serializes to `{"target":"...","method":"...","data":"..."}` format
/// which FlutterBridge parses and routes via MessageRouter.
class _RoutedUnityMessage extends UnityMessage {
  _RoutedUnityMessage({
    required this.target,
    required this.routedMethod,
    required this.routedData,
  }) : super(
          type: 'routed',
          gameObject: 'FlutterBridge',
          method: 'ReceiveMessage',
        );

  final String target;
  final String routedMethod;
  final String routedData;

  @override
  String toJson() {
    return json.encode({
      'target': target,
      'method': routedMethod,
      'data': routedData,
    });
  }
}

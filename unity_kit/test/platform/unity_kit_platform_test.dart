import 'package:flutter_test/flutter_test.dart';
import 'package:unity_kit/src/platform/unity_kit_method_channel.dart';
import 'package:unity_kit/src/platform/unity_kit_platform.dart';

class MockPlatform extends UnityKitPlatform {
  @override
  Future<void> initialize({bool earlyInit = false}) async {}
  @override
  Future<bool> isReady() async => true;
  @override
  Future<bool> isLoaded() async => true;
  @override
  Future<bool> isPaused() async => false;
  @override
  Future<void> postMessage(String go, String method, String msg) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> unload() async {}
  @override
  Future<void> quit() async {}
  @override
  Future<void> dispose(int viewId) async {}
  @override
  Future<void> createUnityPlayer(
      int viewId, Map<String, dynamic> config) async {}
  @override
  void registerViewChannel(int viewId) {}
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  String get viewType => 'test/unity_view';
}

void main() {
  group('UnityKitPlatform', () {
    tearDown(() {
      UnityKitPlatform.instance = UnityKitMethodChannel();
    });

    test('default instance is UnityKitMethodChannel', () {
      expect(UnityKitPlatform.instance, isA<UnityKitMethodChannel>());
    });

    test('instance can be replaced', () {
      final mock = MockPlatform();
      UnityKitPlatform.instance = mock;
      expect(UnityKitPlatform.instance, same(mock));
    });

    test('mock platform returns expected values', () async {
      final mock = MockPlatform();
      UnityKitPlatform.instance = mock;

      expect(await UnityKitPlatform.instance.isReady(), isTrue);
      expect(await UnityKitPlatform.instance.isLoaded(), isTrue);
      expect(await UnityKitPlatform.instance.isPaused(), isFalse);
      expect(UnityKitPlatform.instance.viewType, 'test/unity_view');
    });
  });
}

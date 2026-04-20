import 'package:flutter_test/flutter_test.dart';
import 'package:unity_kit/src/models/unity_config.dart';
import 'package:unity_kit/src/models/platform_view_mode.dart';

void main() {
  group('UnityConfig', () {
    test('has sensible defaults', () {
      const config = UnityConfig();

      expect(config.sceneName, 'MainScene');
      expect(config.fullscreen, isFalse);
      expect(config.unloadOnDispose, isTrue);
      expect(config.hideStatusBar, isFalse);
      expect(config.runImmediately, isTrue);
      expect(config.targetFrameRate, 60);
      expect(config.platformViewMode, PlatformViewMode.hybridComposition);
      expect(config.transparentBackground, isFalse);
    });

    test('accepts custom values', () {
      const config = UnityConfig(
        sceneName: 'TestScene',
        fullscreen: true,
        unloadOnDispose: false,
        hideStatusBar: true,
        runImmediately: false,
        targetFrameRate: 30,
        platformViewMode: PlatformViewMode.virtualDisplay,
        transparentBackground: true,
      );

      expect(config.sceneName, 'TestScene');
      expect(config.fullscreen, isTrue);
      expect(config.unloadOnDispose, isFalse);
      expect(config.hideStatusBar, isTrue);
      expect(config.runImmediately, isFalse);
      expect(config.targetFrameRate, 30);
      expect(config.platformViewMode, PlatformViewMode.virtualDisplay);
      expect(config.transparentBackground, isTrue);
    });

    group('fullscreen factory', () {
      test('creates fullscreen config', () {
        final config = UnityConfig.fullscreen();

        expect(config.fullscreen, isTrue);
        expect(config.hideStatusBar, isTrue);
        expect(config.sceneName, 'MainScene');
      });

      test('accepts custom scene name', () {
        final config = UnityConfig.fullscreen(sceneName: 'GameScene');

        expect(config.sceneName, 'GameScene');
        expect(config.fullscreen, isTrue);
      });

      test('accepts transparentBackground override', () {
        final config = UnityConfig.fullscreen(transparentBackground: true);

        expect(config.transparentBackground, isTrue);
        expect(config.fullscreen, isTrue);
      });
    });

    group('copyWith', () {
      test('copies with no changes', () {
        const original = UnityConfig(sceneName: 'Original');
        final copy = original.copyWith();

        expect(copy.sceneName, 'Original');
        expect(copy.fullscreen, original.fullscreen);
        expect(copy.targetFrameRate, original.targetFrameRate);
      });

      test('copies with specific changes', () {
        const original = UnityConfig();
        final copy = original.copyWith(
          sceneName: 'New',
          fullscreen: true,
          targetFrameRate: 120,
        );

        expect(copy.sceneName, 'New');
        expect(copy.fullscreen, isTrue);
        expect(copy.targetFrameRate, 120);
        expect(copy.unloadOnDispose, original.unloadOnDispose);
      });

      test('copies platformViewMode', () {
        const original = UnityConfig();
        final copy = original.copyWith(
          platformViewMode: PlatformViewMode.textureLayer,
        );

        expect(copy.platformViewMode, PlatformViewMode.textureLayer);
      });

      test('copies transparentBackground', () {
        const original = UnityConfig();
        final copy = original.copyWith(transparentBackground: true);

        expect(copy.transparentBackground, isTrue);
        expect(original.transparentBackground, isFalse);
      });
    });

    group('equality', () {
      test('identical configs are equal', () {
        const a = UnityConfig(transparentBackground: true);
        const b = UnityConfig(transparentBackground: true);

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('configs differ on transparentBackground', () {
        const opaque = UnityConfig();
        const transparent = UnityConfig(transparentBackground: true);

        expect(opaque, isNot(equals(transparent)));
        expect(opaque.hashCode, isNot(equals(transparent.hashCode)));
      });
    });

    group('toString', () {
      test('includes transparentBackground', () {
        const config = UnityConfig(transparentBackground: true);

        expect(config.toString(), contains('transparentBackground: true'));
      });
    });
  });
}

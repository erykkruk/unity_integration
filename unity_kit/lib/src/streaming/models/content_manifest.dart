import 'content_bundle.dart';

/// A versioned manifest describing all available content bundles.
///
/// Example:
/// ```dart
/// final manifest = ContentManifest.fromJson({
///   'version': '1.0.0',
///   'baseUrl': 'https://cdn.example.com/bundles',
///   'bundles': [
///     {'name': 'core', 'url': '/core.bin', 'sizeBytes': 1024, 'isBase': true},
///   ],
/// });
/// ```
class ContentManifest {
  /// Creates a new [ContentManifest].
  const ContentManifest({
    required this.version,
    required this.baseUrl,
    required this.bundles,
    this.catalogUrl,
    this.metadata,
    this.buildTime,
    this.platform,
  });

  /// Parses a [ContentManifest] from a JSON map.
  factory ContentManifest.fromJson(Map<String, dynamic> json) {
    return ContentManifest(
      version: json['version'] as String,
      baseUrl: json['baseUrl'] as String,
      bundles: (json['bundles'] as List<Object?>)
          .map(
            (e) => ContentBundle.fromJson(e! as Map<String, dynamic>),
          )
          .toList(),
      catalogUrl: json['catalogUrl'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      buildTime: json['buildTime'] != null
          ? DateTime.parse(json['buildTime'] as String)
          : null,
      platform: json['platform'] as String?,
    );
  }

  /// Semantic version of this manifest.
  final String version;

  /// Base URL that bundle URLs are relative to.
  final String baseUrl;

  /// URL of the Addressables content catalog (.bin file).
  /// When present, Unity loads the catalog directly and handles bundle
  /// downloads internally via Addressables.
  final String? catalogUrl;

  /// All content bundles described by this manifest.
  final List<ContentBundle> bundles;

  /// Arbitrary metadata attached to this manifest.
  final Map<String, dynamic>? metadata;

  /// When this manifest was built.
  final DateTime? buildTime;

  /// Target platform (e.g., 'android', 'ios').
  final String? platform;

  /// Bundles marked as base content (must be downloaded first).
  List<ContentBundle> get baseBundles =>
      bundles.where((bundle) => bundle.isBase).toList();

  /// Bundles that are not base content (can be streamed on demand).
  List<ContentBundle> get streamingBundles =>
      bundles.where((bundle) => !bundle.isBase).toList();

  /// Total size of all bundles in bytes.
  int get totalSize => bundles.fold(0, (sum, bundle) => sum + bundle.sizeBytes);

  /// Number of bundles in this manifest.
  int get bundleCount => bundles.length;

  /// Returns all bundles belonging to the given [group].
  List<ContentBundle> getBundlesByGroup(String group) {
    return bundles.where((bundle) => bundle.group == group).toList();
  }

  /// Returns the bundle with the given [name], or `null` if not found.
  ContentBundle? getBundleByName(String name) {
    for (final bundle in bundles) {
      if (bundle.name == name) return bundle;
    }
    return null;
  }

  /// Recursively resolves all dependencies for the bundle with [bundleName].
  ///
  /// Returns dependencies in topological order (deepest dependencies first).
  /// Throws [StateError] if a circular dependency is detected.
  List<ContentBundle> resolveDependencies(String bundleName) {
    final resolved = <String>[];
    final visiting = <String>{};

    void visit(String name) {
      if (resolved.contains(name)) return;

      if (visiting.contains(name)) {
        throw StateError('Circular dependency detected: $name');
      }

      visiting.add(name);

      final bundle = getBundleByName(name);
      if (bundle != null) {
        for (final dep in bundle.dependencies) {
          visit(dep);
        }
      }

      visiting.remove(name);
      resolved.add(name);
    }

    final bundle = getBundleByName(bundleName);
    if (bundle == null) return [];

    for (final dep in bundle.dependencies) {
      visit(dep);
    }

    return resolved.map(getBundleByName).whereType<ContentBundle>().toList();
  }

  /// Serializes this manifest to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'baseUrl': baseUrl,
      if (catalogUrl != null) 'catalogUrl': catalogUrl,
      'bundles': bundles.map((b) => b.toJson()).toList(),
      if (metadata != null) 'metadata': metadata,
      if (buildTime != null) 'buildTime': buildTime!.toIso8601String(),
      if (platform != null) 'platform': platform,
    };
  }

  @override
  String toString() =>
      'ContentManifest(version: $version, bundles: $bundleCount)';
}

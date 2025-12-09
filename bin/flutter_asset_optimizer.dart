// bin/flutter_asset_optimizer.dart
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addFlag('preview', abbr: 'p', defaultsTo: true)
    ..addFlag('optimize', abbr: 'o')
    ..addFlag('report', abbr: 'r')
    ..addFlag('confirm', abbr: 'c', negatable: false)
    ..addFlag('help', abbr: 'h');

  late ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    print('Error: $e\n');
    print(parser.usage);
    exit(1);
  }

  if (args['help'] as bool) {
    print('Flutter Asset Optimizer\n${parser.usage}');
    exit(0);
  }

  final config = _loadConfig('asset_optimizer.yaml');
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;

  final assetTypes = (config['asset_types'] as List?)?.cast<String>() ??
      ['png', 'jpg', 'jpeg', 'svg', 'webp', 'gif', 'ttf', 'otf', 'json', 'pdf'];

  final declared = _extractAssets(pubspec, assetTypes);
  if (declared.isEmpty) {
    print('No assets declared in pubspec.yaml');
    return;
  }

  final used = _findAssetReferences(
    Directory('lib'),
    (config['ignore_patterns'] as List?)?.cast<String>() ?? [],
  );

  final unused = declared.where((a) => !used.contains(a)).toList();
  final sizes = _calculateSizes(declared);
  final unusedSizes = _calculateSizes(unused);
  final total = sizes.values.fold(0, (a, b) => a + b);
  final wasted = unusedSizes.values.fold(0, (a, b) => a + b);

  if (args['preview'] as bool || args['report'] as bool) {
    _preview(unused, unusedSizes, total, wasted);
  }
  if (args['report'] as bool) _report(unused, unusedSizes);

  if (args['optimize'] as bool) {
    if (!(args['confirm'] as bool)) {
      print('Use --confirm to actually delete and compress');
      return;
    }
    final deleted = _deleteUnused(unused);
    final saved = _compress(declared, config['compression_quality'] as int? ?? 80);
    print('\nDone! Deleted: ${_format(wasted)} | Compressed: ${_format(saved)}');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _loadConfig(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return {'ignore_patterns': <String>[], 'compression_quality': 80};
  }
  try {
    final yaml = loadYaml(file.readAsStringSync());
    return yaml is Map ? Map<String, dynamic>.from(yaml) : {};
  } catch (_) {
    return {'ignore_patterns': <String>[], 'compression_quality': 80};
  }
}

List<String> _extractAssets(YamlMap pubspec, List<String> types) {
  final list = pubspec['flutter']?['assets'] as YamlList? ?? YamlList();
  return list
      .whereType<String>()
      .where((s) => types.any((ext) => s.toLowerCase().endsWith('.$ext')))
      .toList();
}

Set<String> _findAssetReferences(Directory libDir, List<String> ignore) {
  final used = <String>{};
  if (!libDir.existsSync()) return used;

  final ignoreRes = ignore.map((p) => RegExp(p, caseSensitive: false)).toList();

  // CLEAN, WORKING regexes – copy exactly as-is
  final patterns = <RegExp>[
  RegExp(r'''AssetImage\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
  RegExp(r'''Image\.asset\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
  RegExp(r'''rootBundle\.load(String)?\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
  RegExp(r'''['"](assets?/[^'"]+\.(png|jpe?g|jpeg|webp|gif|svg|ttf|otf|json|pdf|yaml|yml))['"]''',
      caseSensitive: false),
];

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (ignoreRes.any((r) => r.hasMatch(p.relative(entity.path)))) continue;

    final content = entity.readAsStringSync();
    for (final re in patterns) {
      for (final m in re.allMatches(content)) {
        final path = m.group(1);
        if (path != null) {
          final clean = path.startsWith('./') ? path.substring(2) : path;
          if (clean.startsWith('assets/') || clean.startsWith('asset/')) {
            used.add(clean);
          }
        }
      }
    }
  }
  return used;
}

Map<String, int> _calculateSizes(List<String> paths) {
  final map = <String, int>{};
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) map[p] = f.lengthSync();
  }
  return map;
}

void _preview(List<String> unused, Map<String, int> sizes, int total, int wasted) {
  print('\nFound ${unused.length} unused assets → ${_format(wasted)} wasted');
  if (unused.isEmpty) {
    print('All assets are used!');
    return;
  }
  for (final p in unused) {
    print('  • $p (${_format(sizes[p] ?? 0)})');
  }
}

void _report(List<String> unused, Map<String, int> sizes) {
  final f = File('asset_optimizer_report.txt');
  f.writeAsStringSync(
    'Unused assets (${DateTime.now()}):\n' +
    '${unused.map((p) => '• $p (${_format(sizes[p] ?? 0)})').join('\n')}\n',
  );
  print('Report saved → ${f.path}');
}

int _deleteUnused(List<String> unused) {
  int saved = 0;
  for (final p in unused) {
    final f = File(p);
    if (f.existsSync()) {
      saved += f.lengthSync();
      f.deleteSync();
      print('Deleted: $p');
    }
  }
  return saved;
}

int _compress(List<String> assets, int quality) {
  int saved = 0;
  for (final p in assets) {
    if (!RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(p)) continue;
    final f = File(p);
    final bytes = f.readAsBytesSync();
   final decoded = img.decodeImage(bytes);
if (decoded == null) continue;

List<int> compressed;
if (p.toLowerCase().endsWith('.png')) {
  final level = max(0, min(9, (100 - quality) ~/ 11));
  compressed = img.encodePng(decoded, level: level);
} else {
  compressed = img.encodeJpg(decoded, quality: quality);
}


    if (compressed.length < bytes.length) {
      f.writeAsBytesSync(compressed);
      saved += bytes.length - compressed.length;
      print('Compressed: $p → saved ${_format(bytes.length - compressed.length)}');
    }
  }
  return saved;
}

String _format(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1048576).toStringAsFixed(2)} MB';
}
// task-40 c8-pdf-impl：真实引擎链路覆盖。
// 现有 pdf_import_test.dart 全用 mock 文档，只证明编排逻辑；本文件跑真 pdfium，
// 移植 VeneraX 上游 pdf_import_test.dart 的真机断言（页序/cover/口径/旋转/超大页/
// 颜色/源文件 untouched/失败无残留），按 unified 口径（3.0/3000、JPG、session）改写期望值。
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/local_comics/import_export/import_export.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> initPdfEngine() async {
    // pdfrxFlutterInitialize 内部调 path_provider：测试里 mock 掉。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getTemporaryDirectory') {
              return Directory.systemTemp.path;
            }
            return null;
          },
        );
    await pdfrxFlutterInitialize();
  }

  group(
    'real engine rendering',
    () {
      late Directory root;

      setUpAll(initPdfEngine);

      setUp(() {
        root = Directory.systemTemp.createTempSync('venera-pdf-engine-');
      });

      tearDown(() => root.deleteSync(recursive: true));

      test('renders rotated and oversized pages with exact pixels', () async {
        final source = File(FilePath.join(root.path, 'vector.pdf'))
          ..writeAsBytesSync(_vectorPdf(pageCount: 3));
        final document = await PdfDocument.openFile(source.path);
        try {
          expect(document.pages, hasLength(3));
          // 口径：3.0/3000（calculatePdfRenderSize 默认值）。
          // p0 红 100x200 → 300x600；p1 绿 100x200+Rotate90 → 600x300；
          // p2 蓝 10000x5000 → 封顶 3000x1500。
          const expected = [(300, 600), (600, 300), (3000, 1500)];
          // PdfImage.pixels 是 BGRA 字节序：红=[0,0,255,255]，蓝=[255,0,0,255]。
          const expectedBgra = [
            [0, 0, 255, 255],
            [0, 255, 0, 255],
            [255, 0, 0, 255],
          ];
          for (var i = 0; i < 3; i++) {
            final page = document.pages[i];
            final size = calculatePdfRenderSize(page.width, page.height);
            final rendered = await page.render(
              fullWidth: size.width.toDouble(),
              fullHeight: size.height.toDouble(),
            );
            expect(rendered, isNotNull);
            try {
              expect((rendered!.width, rendered.height), expected[i]);
              final center =
                  ((rendered.height ~/ 2) * rendered.width +
                      rendered.width ~/ 2) *
                  4;
              expect(
                rendered.pixels.sublist(center, center + 4),
                expectedBgra[i],
              );
            } finally {
              rendered!.dispose();
            }
          }
        } finally {
          await document.dispose();
        }
      });

      test('openFile rejects damaged bytes', () async {
        final source = File(FilePath.join(root.path, 'invalid.pdf'));
        for (final bytes in [utf8.encode('not a PDF'), <int>[]]) {
          source.writeAsBytesSync(bytes);
          await expectLater(
            PdfDocument.openFile(source.path),
            throwsA(anything),
          );
          expect(source.readAsBytesSync(), bytes);
        }
      });
    },
    skip: _pdfiumAvailable() ? false : 'pdfium native library is unavailable',
  );

  group('real PDF import lifecycle', () {
    late Directory dataDirectory;
    late Directory cacheDirectory;
    late Directory root;
    late LocalManager manager;

    setUpAll(initPdfEngine);

    setUp(() async {
      dataDirectory = Directory.systemTemp.createTempSync('venera-pdf-data-');
      cacheDirectory = Directory.systemTemp.createTempSync('venera-pdf-cache-');
      root = Directory.systemTemp.createTempSync('venera-pdf-src-');
      App.dataPath = dataDirectory.path;
      App.cachePath = cacheDirectory.path;
      LocalManager.current?.dispose();
      LocalManager(initializeSources: () async {});
      manager = LocalManager();
      await manager.init();
    });

    tearDown(() {
      LocalManager.current?.dispose();
      dataDirectory.deleteSync(recursive: true);
      cacheDirectory.deleteSync(recursive: true);
      root.deleteSync(recursive: true);
    });

    test(
      'imports pages in reader order with cover and unified caliber',
      () async {
        final source = File(FilePath.join(root.path, '漫画.pdf'))
          ..writeAsBytesSync(_vectorPdf(pageCount: 3));
        final original = source.readAsBytesSync();
        final progress = <(int, int)>[];
        final comic = await PdfComicImporter.import(
          source,
          onProgress: (current, total) => progress.add((current, total)),
        );

        expect(comic.title, '漫画');
        expect(comic.chapters, isNull);
        expect(comic.cover, 'cover.jpg');
        expect(progress, [(0, 3), (1, 3), (2, 3), (3, 3)]);
        // JPEG 有损：只断言主导通道。
        const expected = [
          (300, 600, _Channel.red),
          (600, 300, _Channel.green),
          (3000, 1500, _Channel.blue),
        ];
        for (var i = 0; i < 3; i++) {
          final bytes = File(
            FilePath.join(
              comic.baseDir,
              '${(i + 1).toString().padLeft(4, '0')}.jpg',
            ),
          ).readAsBytesSync();
          final decoded = image.decodeJpg(bytes)!;
          expect(
            (decoded.width, decoded.height),
            (expected[i].$1, expected[i].$2),
          );
          final center = decoded.getPixel(
            decoded.width ~/ 2,
            decoded.height ~/ 2,
          );
          expect(_dominant(center.r, center.g, center.b), expected[i].$3);
        }
        expect(
          comic.coverFile.readAsBytesSync(),
          File(FilePath.join(comic.baseDir, '0001.jpg')).readAsBytesSync(),
        );
        expect(source.readAsBytesSync(), original);
      },
    );

    test('rejects damaged and empty PDFs without leaving output', () async {
      final source = File(FilePath.join(root.path, 'invalid.pdf'));
      for (final bytes in [
        utf8.encode('not a PDF'),
        <int>[],
        _vectorPdf(pageCount: 0),
      ]) {
        source.writeAsBytesSync(bytes);
        await expectLater(PdfComicImporter.import(source), throwsA(anything));
        expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        expect(source.readAsBytesSync(), bytes);
      }
    });

    test(
      'failed conversion keeps the existing folder and retry dedupes',
      () async {
        final source = File(FilePath.join(root.path, 'comic.pdf'))
          ..writeAsBytesSync(_vectorPdf(pageCount: 2));
        final existing = Directory(FilePath.join(manager.path, 'comic'))
          ..createSync();
        final sentinel = File(FilePath.join(existing.path, 'sentinel.txt'))
          ..writeAsStringSync('untouched');
        await expectLater(
          PdfComicImporter.import(
            source,
            onProgress: (current, total) {
              if (current == 1) {
                throw const FileSystemException('No space left on device');
              }
            },
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          manager.directory.listSync().whereType<Directory>().map(
            (dir) => dir.path,
          ),
          [existing.path],
        );
        expect(sentinel.readAsStringSync(), 'untouched');
        expect(source.existsSync(), isTrue);

        final comic = await PdfComicImporter.import(source);
        expect(comic.directory, isNot('comic'));
        for (var i = 1; i <= 2; i++) {
          expect(
            File(
              FilePath.join(
                comic.baseDir,
                '${i.toString().padLeft(4, '0')}.jpg',
              ),
            ).existsSync(),
            isTrue,
          );
        }
      },
    );
  }, skip: _lifecycleSkipReason());
}

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

/// lifecycle 组两个原生依赖都要在 setUpAll 里初始化，缺哪个报哪个。
Object? _lifecycleSkipReason() {
  if (!_pdfiumAvailable()) return 'pdfium native library is unavailable';
  if (!_sqliteAvailable()) return 'sqlite3 native library is unavailable';
  return false;
}

/// 与 pdfium_dart 0.2.5 `lib/src/pdfium_loader.dart` 主策略对齐的同步探针：
/// Linux Flutter（含 flutter test）找测试执行文件旁的 `lib/libpdfium.so`，
/// Windows 按名找 `pdfium.dll`，其它平台在该 loader 下本就没有主策略。
/// 误判只会让本文件 skip（setUpAll 本来就会因同样的缺库而抛），不会误绿。
bool _pdfiumAvailable() {
  try {
    if (Platform.isLinux) {
      final engineLib =
          '${File(Platform.resolvedExecutable).parent.path}/lib/libpdfium.so';
      if (!File(engineLib).existsSync()) return false;
      DynamicLibrary.open(engineLib);
    } else if (Platform.isWindows) {
      DynamicLibrary.open('pdfium.dll');
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

enum _Channel { red, green, blue }

_Channel _dominant(num r, num g, num b) {
  if (r > 200 && g < 130 && b < 130) return _Channel.red;
  if (g > 200 && r < 130 && b < 130) return _Channel.green;
  if (b > 200 && r < 130 && g < 130) return _Channel.blue;
  throw StateError('no dominant channel: ($r, $g, $b)');
}

/// 移植自 VeneraX 上游 pdf_import_test.dart 的 fixture：最小矢量 PDF，
/// 整页纯色、p1 带 /Rotate 90、p2 超大页（仅当 pageCount > 2 时存在）。
List<int> _vectorPdf({required int pageCount}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pageCount /Kids [${List.generate(pageCount, (i) => '${3 + i * 2} 0 R').join(' ')}] >>',
  ];
  for (var i = 0; i < pageCount; i++) {
    final (width, height) = i == 2 ? (10000, 5000) : (100, 200);
    final color = ['1 0 0', '0 1 0', '0 0 1'][i % 3];
    final stream = '$color rg 0 0 $width $height re f\n';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
      '/Rotate ${i == 1 ? 90 : 0} /Resources << >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add('<< /Length ${stream.length} >>\nstream\n${stream}endstream');
  }
  final result = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(result.length);
    result.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = result.length;
  result.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    result.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  result.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(result.toString());
}

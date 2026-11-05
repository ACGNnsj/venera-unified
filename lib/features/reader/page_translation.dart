import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/image_translation/ocr_engine.dart';
import 'package:venera_unified/foundation/image_translation/ocr_models.dart';
import 'package:venera_unified/foundation/image_translation/ocr_types.dart';
import 'package:venera_unified/foundation/image_translation/public_translator.dart';
import 'package:venera_unified/foundation/translations.dart';

/// One recognized block paired with its translation, in reading order.
class TranslatedBlock {
  TranslatedBlock({
    required this.source,
    required this.translation,
    required this.rect,
    required this.imageWidth,
    required this.imageHeight,
  });

  final String source;
  final String translation;

  /// OCR box in source-image pixels; the image is [imageWidth]x[imageHeight].
  final IntRect rect;
  final int imageWidth;
  final int imageHeight;
}

/// Translates one reader page: OCR the image, then machine-translate the
/// recognized blocks into the reader's target language.
///
/// The pipeline runs here (not inline in the reader) so taps and page turns
/// keep working while it runs, and a failure surfaces a retry entry instead
/// of failing silently.
class PageTranslationPage extends StatefulWidget {
  const PageTranslationPage({
    super.key,
    required this.imageBytes,
    required this.targetLang,
    required this.pageLabel,
  });

  final Uint8List imageBytes;
  final String targetLang;
  final String pageLabel;

  @override
  State<PageTranslationPage> createState() => _PageTranslationPageState();
}

enum _Stage { downloading, recognizing, translating, done, error }

class _PageTranslationPageState extends State<PageTranslationPage> {
  var _stage = _Stage.downloading;
  var _progress = 0.0;
  var _blocks = const <TranslatedBlock>[];
  var _error = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.downloading;
      _progress = 0;
      _error = '';
    });
    List<OcrBlock> blocks;
    try {
      blocks = await OcrEngine.recognizePage(
        widget.imageBytes,
        onDownloadProgress: (index, count, received, total) {
          if (!mounted || total <= 0) return;
          setState(() {
            // The worker isolate starts recognizing right after the last
            // byte lands; flip the label so the stall has a name.
            _stage = received >= total
                ? _Stage.recognizing
                : _Stage.downloading;
            _progress = (received / total).clamp(0.0, 1.0);
          });
        },
      );
    } on OcrModelException catch (e) {
      if (mounted) _fail(e.message);
      return;
    } catch (e) {
      if (mounted) _fail(e.toString());
      return;
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.translating);
    List<String> translated;
    try {
      translated = await PublicTranslator.translate([
        for (var block in blocks) block.text,
      ], widget.targetLang);
    } catch (e) {
      if (mounted) _fail(e.toString());
      return;
    }
    if (!mounted) return;
    final decoded = img.decodeImage(widget.imageBytes);
    setState(() {
      _blocks = [
        for (var i = 0; i < blocks.length; i++)
          TranslatedBlock(
            source: blocks[i].text,
            translation: translated[i],
            rect: blocks[i].rect,
            imageWidth: decoded?.width ?? 1,
            imageHeight: decoded?.height ?? 1,
          ),
      ];
      _stage = _Stage.done;
    });
  }

  void _fail(String error) {
    setState(() {
      _error = error;
      _stage = _Stage.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text('${'Translate page'.tl} ${widget.pageLabel}')),
      body: switch (_stage) {
        _Stage.done => _buildResults(),
        _Stage.error => _buildError(),
        _ => _buildProgress(),
      },
    );
  }

  Widget _buildProgress() {
    final label = switch (_stage) {
      _Stage.downloading when _progress <= 0 =>
        'Preparing translation models…'.tl,
      _Stage.downloading =>
        '${'Downloading translation models…'.tl} ${(100 * _progress).toStringAsFixed(0)}%',
      _Stage.recognizing => 'Recognizing text…'.tl,
      _Stage.translating => 'Translating…'.tl,
      _ => '',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_stage == _Stage.downloading && _progress > 0)
              LinearProgressIndicator(value: _progress)
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_blocks.isEmpty) {
      return Center(child: Text('No text found on this page'.tl));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _blocks.length,
      itemBuilder: (context, index) {
        final block = _blocks[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.to(
              () => _BlockHighlightPage(
                imageBytes: widget.imageBytes,
                block: block,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    block.source,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Divider(height: 16),
                  SelectableText(block.translation),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(_error, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.refresh),
              label: Text('Retry'.tl),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the source image with one recognized block boxed, so a translation
/// can be matched back to the bubble it came from. Tap anywhere to go back.
class _BlockHighlightPage extends StatelessWidget {
  const _BlockHighlightPage({required this.imageBytes, required this.block});

  final Uint8List imageBytes;
  final TranslatedBlock block;

  @override
  Widget build(BuildContext context) {
    double clamp01(double v) => v.clamp(0.0, 1.0);
    final left = clamp01(block.rect.left / block.imageWidth);
    final top = clamp01(block.rect.top / block.imageHeight);
    final right = clamp01(block.rect.right / block.imageWidth);
    final bottom = clamp01(block.rect.bottom / block.imageHeight);
    return Scaffold(
      appBar: Appbar(title: Text('Locate on page'.tl)),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.pop(),
        child: Center(
          child: SingleChildScrollView(
            child: AspectRatio(
              aspectRatio: block.imageWidth / block.imageHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  return Stack(
                    children: [
                      Image.memory(
                        imageBytes,
                        width: w,
                        height: h,
                        fit: BoxFit.fill,
                      ),
                      Positioned(
                        left: left * w,
                        top: top * h,
                        width: (right - left) * w,
                        height: (bottom - top) * h,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: context.colorScheme.error,
                              width: 3,
                            ),
                            color: context.colorScheme.error.withValues(
                              alpha: 0.15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

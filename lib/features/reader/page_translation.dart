import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/image_translation/ocr_engine.dart';
import 'package:venera_unified/foundation/image_translation/ocr_models.dart';
import 'package:venera_unified/foundation/image_translation/ocr_types.dart';
import 'package:venera_unified/foundation/image_translation/public_translator.dart';
import 'package:venera_unified/foundation/translations.dart';

/// One recognized block paired with its translation, in reading order.
class TranslatedBlock {
  TranslatedBlock({required this.source, required this.translation});

  final String source;
  final String translation;
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
    setState(() {
      _blocks = [
        for (var i = 0; i < blocks.length; i++)
          TranslatedBlock(source: blocks[i].text, translation: translated[i]),
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

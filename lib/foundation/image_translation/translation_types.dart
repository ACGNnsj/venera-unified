import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/file_system.dart';

/// Raw RGBA bitmap that can cross isolate boundaries.
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Integer rectangle (isolate-friendly, no dart:ui types).
class IntRect {
  IntRect(this.left, this.top, this.right, this.bottom);

  int left, top, right, bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;

  bool intersects(IntRect other) {
    return left < other.right &&
        other.left < right &&
        top < other.bottom &&
        other.top < bottom;
  }

  IntRect inflated(int dx, int dy, int maxW, int maxH) {
    return IntRect(
      (left - dx).clamp(0, maxW),
      (top - dy).clamp(0, maxH),
      (right + dx).clamp(0, maxW),
      (bottom + dy).clamp(0, maxH),
    );
  }
}

/// One recognized text block, produced by the worker isolate.
class OcrBlock {
  OcrBlock({
    required this.rect,
    IntRect? eraseRect,
    List<IntRect>? eraseRects,
    required this.text,
    required this.language,
    required this.backgroundColor,
    required this.textColor,
    this.lineHeight = 0,
  }) : eraseRect = eraseRect ?? rect,
       eraseRects = eraseRects ?? [eraseRect ?? rect];

  /// Area available to the translated lettering.
  final IntRect rect;

  /// Tighter detected-source area used only for removing the original glyphs.
  final IntRect eraseRect;

  /// Individual detected text-line areas. Keeping gaps out of these masks
  /// prevents nearby artwork inside the block bounds from being erased.
  final List<IntRect> eraseRects;

  /// Recognized source text.
  final String text;

  /// Detected source language ('ja', 'zh', 'ko', 'en').
  final String language;

  final int backgroundColor;
  final int textColor;

  /// Median height (px) of the original text lines in this block — the source
  /// lettering's approximate font size. The renderer caps the translated glyph
  /// size to this so a small original caption stays small instead of growing to
  /// fill the whole detected box. 0 means unknown (fall back to box-based fit).
  final int lineHeight;
}

/// A translated text block ready for rendering.
class TranslatedRegion {
  TranslatedRegion({
    required this.rect,
    IntRect? eraseRect,
    List<IntRect>? eraseRects,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
    this.lineHeight = 0,
  }) : eraseRect = eraseRect ?? rect,
       eraseRects = eraseRects ?? [eraseRect ?? rect];

  /// Area available to the translated lettering.
  final IntRect rect;

  /// Tighter source-text area. Kept separate so erasing never has to cover the
  /// full layout box when the translation needs more room.
  final IntRect eraseRect;

  /// Per-line source rectangles used by the inpainter. [eraseRect] remains as
  /// the backward-compatible union for older cached results.
  final List<IntRect> eraseRects;
  final String text;
  final int backgroundColor;
  final int textColor;

  /// Original lettering's approximate font size (px), carried from OCR so the
  /// renderer can keep the translated glyphs close to the source size instead
  /// of scaling them to fill the detected box. 0 = unknown (box-based fit).
  final int lineHeight;

  /// Compact JSON for the text-level result cache: lets a page be re-rendered
  /// after the rendered image was evicted, without re-running OCR or paying
  /// for another translation request.
  Map<String, dynamic> toJson() => {
    'l': rect.left,
    't': rect.top,
    'r': rect.right,
    'b': rect.bottom,
    'text': text,
    'bg': backgroundColor,
    'fg': textColor,
    if (!_sameRect(eraseRect, rect)) ...{
      'el': eraseRect.left,
      'et': eraseRect.top,
      'er': eraseRect.right,
      'eb': eraseRect.bottom,
    },
    if (!_sameEraseRects(eraseRects, eraseRect))
      'es': [
        for (var rect in eraseRects)
          [rect.left, rect.top, rect.right, rect.bottom],
      ],
    if (lineHeight > 0) 'lh': lineHeight,
  };

  factory TranslatedRegion.fromJson(Map<String, dynamic> json) {
    var rect = IntRect(json['l'], json['t'], json['r'], json['b']);
    var eraseRect = json['el'] == null
        ? rect
        : IntRect(json['el'], json['et'], json['er'], json['eb']);
    var storedEraseRects = json['es'];
    var eraseRects = <IntRect>[];
    if (storedEraseRects is List) {
      for (var stored in storedEraseRects) {
        if (stored is List &&
            stored.length == 4 &&
            stored.every((value) => value is num)) {
          var candidate = IntRect(
            (stored[0] as num).toInt(),
            (stored[1] as num).toInt(),
            (stored[2] as num).toInt(),
            (stored[3] as num).toInt(),
          );
          if (candidate.width > 0 && candidate.height > 0) {
            eraseRects.add(candidate);
          }
        }
      }
    }
    return TranslatedRegion(
      rect: rect,
      eraseRect: eraseRect,
      eraseRects: eraseRects.isEmpty ? null : eraseRects,
      text: json['text'],
      backgroundColor: json['bg'],
      textColor: json['fg'],
      lineHeight: json['lh'] ?? 0,
    );
  }

  static bool _sameRect(IntRect a, IntRect b) =>
      a.left == b.left &&
      a.top == b.top &&
      a.right == b.right &&
      a.bottom == b.bottom;

  static bool _sameEraseRects(List<IntRect> rects, IntRect eraseRect) =>
      rects.length == 1 && _sameRect(rects.single, eraseRect);
}

class PipelineCanceled implements Exception {
  const PipelineCanceled();
}

/// How the original lettering is removed before the translation is drawn.
///
/// The mode is part of the rendered-image cache key (a one-char token), so
/// switching it re-renders from the already-stored text result without
/// re-running OCR or the LLM, and switching back serves the earlier render.
enum InpaintMode {
  /// Legacy: cover each region with an opaque rounded patch in the sampled
  /// background colour. Fast and universal, but a big bubble becomes a big
  /// solid block and a textured/translucent bubble gets a pasted-on look.
  patch('p'),

  /// Pure-Dart erase: estimate the text strokes inside each region and fill
  /// only those pixels from the surrounding non-text pixels, keeping the
  /// bubble shape, screentone and gradients. A backing plate is added only
  /// where the placed translation would be hard to read. Default.
  smart('s');

  const InpaintMode(this.token);

  /// One-character tag appended to the rendered-image cache key.
  final String token;

  static InpaintMode fromSettings(Object? value) {
    return switch (value) {
      'patch' => InpaintMode.patch,
      _ => InpaintMode.smart,
    };
  }
}

/// Coarse phase of one page group's work, surfaced to the task list.
///
/// Display only: it never drives control flow and never feeds the resume
/// cursor. Pre-translation commits a whole group's page counts at once to keep
/// `done + failed` a contiguous prefix, so between commits the only honest
/// signal that a job is alive is which phase it is in.
enum TranslationStage {
  /// Downloading the group's source images.
  fetching,

  /// First recognition of the run — the OCR isolate is still loading models.
  loadingModel,

  /// Running text detection and recognition.
  recognizing,

  /// Waiting on the translation request for the whole group.
  translating,

  /// Erasing the source text and drawing the translation.
  rendering,
}

/// Weight of a page that has been downloaded but not yet recognized, on the
/// page-unit scale progress is reported in. Lives here because the fetch half
/// of the pipeline and the recognize/translate/render half score pages
/// separately and must agree on what a half-finished page is worth.
const double fetchedPageWeight = 0.15;

/// Hard ceiling for one translation request, transport level included.
///
/// Lives here (not on [LlmTranslator]) so both the LLM and the script
/// translators can share it without importing each other.
const Duration llmRequestTimeout = Duration(minutes: 3);

/// One page's translation outcome: the per-bubble texts (aligned with the
/// input, empty where the model refused/failed) plus any proper-noun
/// renderings the model reported for this page, which the caller folds back
/// into the comic's glossary so later pages/chapters stay consistent.
class LlmTranslationResult {
  const LlmTranslationResult(this.texts, this.glossary);

  final List<String> texts;

  /// source term -> agreed translation, discovered on this page.
  final Map<String, String> glossary;
}

/// Which translation engine a provider entry stands for.
enum LlmProviderKind {
  /// A user-supplied OpenAI-compatible chat endpoint. Needs URL + model.
  openai('openai'),

  /// Google Translate's free endpoint. Needs no configuration at all, so its
  /// URL/key/model stay empty.
  publicFree('public'),

  customScript('script');

  const LlmProviderKind(this.token);

  final String token;

  static LlmProviderKind fromToken(dynamic token) {
    for (var kind in values) {
      if (kind.token == token) return kind;
    }
    // Entries written before this field existed are all OpenAI-compatible.
    return openai;
  }
}

/// One configured translation service: a stable [id], a display [name], and —
/// for an OpenAI-compatible entry — the endpoint/credential/model triple that
/// used to be the app's single global config. Users keep several of these and
/// pick which one is active, so they can switch between vendors (or a paid
/// account and a LAN gateway) without re-typing settings each time.
///
/// A [LlmProviderKind.publicFree] entry is the exception: it carries no
/// endpoint, key or model, because that service needs none.
class LlmProvider {
  LlmProvider({
    required this.id,
    required this.name,
    required this.url,
    required this.key,
    required this.model,
    this.kind = LlmProviderKind.openai,
    this.script = '',
  });

  final String id;
  final String name;
  final String url;
  final String key;
  final String model;
  final LlmProviderKind kind;
  // Stored separately by LlmProviderStore; never included in synced metadata.
  final String script;

  bool get isPublicFree => kind == LlmProviderKind.publicFree;
  bool get isCustomScript => kind == LlmProviderKind.customScript;

  LlmProvider copyWith({
    String? name,
    String? url,
    String? key,
    String? model,
    LlmProviderKind? kind,
    String? script,
  }) {
    return LlmProvider(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      key: key ?? this.key,
      model: model ?? this.model,
      kind: kind ?? this.kind,
      script: script ?? this.script,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'key': key,
    'model': model,
    'kind': kind.token,
  };

  static LlmProvider? fromJson(dynamic json) {
    if (json is! Map) return null;
    var id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return LlmProvider(
      id: id,
      name: (json['name'] as String?)?.trim() ?? '',
      url: (json['url'] as String?)?.trim() ?? '',
      key: (json['key'] as String?)?.trim() ?? '',
      model: (json['model'] as String?)?.trim() ?? '',
      kind: LlmProviderKind.fromToken(json['kind']),
    );
  }
}

bool isValidLlmBaseUrl(String rawUrl) {
  var uri = Uri.tryParse(rawUrl.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

final _llmUrlLike = RegExp(
  r'https?://|www\.|@|[./\\][a-zA-Z]{2,}|\.(com|net|org|io|cn|jp)\b',
  caseSensitive: false,
);

final _llmSentenceLike = RegExp(r'[。！？.!?、,，；;]|\s{1,}\S+\s');

final _llmNumericOnly = RegExp(r'^[0-9\s.,]+$');

/// Whether a reported name/translation pair is worth keeping in the glossary.
/// The glossary exists only for short proper nouns (names, places, techniques)
/// that must stay consistent across pages; it is sent with every request, so
/// it must stay small. Models occasionally return whole sentences, URLs or
/// numbers as "names" — those bloat the prompt without helping consistency,
/// so they are rejected here as a backstop to the prompt's own instruction.
/// Also used by the service to sanitize a glossary loaded from an earlier
/// version that had no such filtering.
bool isValidLlmGlossaryTerm(String source, String translation) {
  if (source.isEmpty || translation.isEmpty) return false;
  // Proper nouns are short. Anything long is almost certainly a sentence.
  if (source.length > 16 || translation.length > 16) return false;
  for (var s in [source, translation]) {
    // URLs / emails / paths — never proper nouns, and long enough to bloat.
    if (_llmUrlLike.hasMatch(s)) return false;
    // Sentence-like: contains terminal/comma punctuation or whitespace runs
    // typical of a clause rather than a single term.
    if (_llmSentenceLike.hasMatch(s)) return false;
  }
  // Pure numbers (page numbers, counts) carry no naming to keep consistent.
  if (_llmNumericOnly.hasMatch(source)) return false;
  return true;
}

/// A single downloadable file of a model component. [urls] is a fallback
/// chain: mirrors are tried in order, so a blocked host does not make the
/// component impossible to install.
///
/// Lives in the shared types (not translation_models.dart) so the custom
/// source registry (translation_sources.dart) can describe its components
/// without importing the whole model store: the lane's dependency gate
/// requires an acyclic business graph, and the registry/store pair is
/// inherently bidirectional upstream.
class ModelFile {
  const ModelFile(this.name, this.urls);

  /// File name inside the component directory.
  final String name;

  /// Candidate URLs. `{hf}` is replaced with the configured HuggingFace
  /// endpoint (official or mirror) at download time.
  final List<String> urls;
}

/// A downloadable model component (detector / OCR / translator).
class ModelComponent {
  const ModelComponent({
    required this.id,
    required this.files,
    required this.approxSizeBytes,
    this.marker = false,
  });

  final String id;
  final List<ModelFile> files;

  /// Rough total download size, for display before downloading.
  final int approxSizeBytes;

  /// User-supplied models count as installed only after a check run wrote
  /// [markerName], so a file that downloaded but cannot be used never does.
  final bool marker;

  static const markerName = 'verified';

  String get directory =>
      FilePath.join(App.dataPath, 'translation_models', id);

  bool get isInstalled {
    for (var file in files) {
      var f = File(FilePath.join(directory, file.name));
      if (!f.existsSync() || f.lengthSync() == 0) {
        return false;
      }
    }
    return !marker || File(FilePath.join(directory, markerName)).existsSync();
  }

  String filePath(String name) => FilePath.join(directory, name);
}

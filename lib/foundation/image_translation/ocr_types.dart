// Canonical translation/OCR shared types live in [translation_types.dart]
// (ported phase 1 from VeneraX `translation_types.dart`).
// This file re-exports them so existing `ocr_types.dart` imports
// (ocr_engine, ocr_worker) keep working without ambiguous imports:
// import exactly one of the two files, never both for the same symbol.
export 'translation_types.dart';

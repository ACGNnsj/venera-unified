import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows AVIF decode fallback built on WIC (Windows Imaging Component).
///
/// The Windows Flutter engine renders through Impeller, whose image decoder
/// rejects AVIF: every sample fails with `Could not decompress image` even
/// though the OS itself decodes them fine. The reader therefore gets one last
/// chance through WIC, which serves AVIF through the installed HEIF/AV1 codec
/// extensions. Nothing is bundled: a host without those extensions simply
/// keeps failing to decode, and every failure path returns null so the
/// existing placeholder handling stays in charge. This decoder must never
/// crash the app, only decline.

/// `CLSID_WICImagingFactory`.
const List<int> _clsidWicImagingFactory = [
  0xCACAF262,
  0x9370,
  0x4615,
  0xA1,
  0x3B,
  0x9F,
  0x55,
  0x39,
  0xDA,
  0x4C,
  0x0A,
];

/// `IID_IWICImagingFactory`.
const List<int> _iidWicImagingFactory = [
  0xEC5EC8A9,
  0xC395,
  0x4314,
  0x9C,
  0x77,
  0x54,
  0xD7,
  0xA9,
  0x35,
  0xFF,
  0x70,
];

/// `GUID_WICPixelFormat32bppBGRA`: WIC's normalised output format.
const List<int> _pixelFormat32bppBgra = [
  0x6FDDC324,
  0x4E03,
  0x4BFE,
  0xB1,
  0x85,
  0x3D,
  0x77,
  0x76,
  0x8D,
  0xC9,
  0x0F,
];

const int _clsctxInprocServer = 1;
const int _coinitApartmentThreaded = 0x2;
const int _rpcEChangedMode = 0x80010106;
const int _sicOk = 0;
const int _sfcOk = 1;
const int _wicDecodeMetadataCacheOnDemand = 0;
const int _wicBitmapDitherTypeNone = 0;
const int _wicBitmapPaletteTypeCustom = 0;

/// COM vtable slots. IUnknown occupies 0..2; every interface below continues
/// from there. Slots follow wincodec.h.
const int _vtableRelease = 2;
// IWICImagingFactory.
const int _factoryCreateDecoderFromStream = 4;
const int _factoryCreateFormatConverter = 10;
const int _factoryCreateStream = 14;
// IWICStream derives from IStream, so its own methods start after IUnknown (3)
// plus ISequentialStream (2) plus IStream (9): InitializeFromIStream 14,
// InitializeFromFilename 15, InitializeFromMemory 16.
const int _streamInitializeFromMemory = 16;
// IWICBitmapDecoder's own methods follow IUnknown: GetFrame is the last one.
const int _decoderGetFrame = 13;
// IWICBitmapSource slots 3..7 (GetSize, GetPixelFormat, GetResolution,
// CopyPalette, CopyPixels), inherited unchanged by IWICFormatConverter.
const int _sourceGetSize = 3;
const int _sourceGetPixelFormat = 4;
const int _sourceCopyPixels = 7;
// IWICFormatConverter::Initialize, first method after IWICBitmapSource.
const int _converterInitialize = 8;

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

final class _WicRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int width;
  @Int32()
  external int height;
}

typedef _GetPixelFormatNative = Int32 Function(Pointer<Void>, Pointer<_Guid>);
typedef _GetPixelFormatDart = int Function(Pointer<Void>, Pointer<_Guid>);

typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeExDart = int Function(Pointer<Void>, int);
typedef _CoUninitializeNative = Void Function();
typedef _CoUninitializeDart = void Function();
typedef _CoCreateInstanceNative =
    Int32 Function(
      Pointer<_Guid>,
      Pointer<Void>,
      Uint32,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );
typedef _CoCreateInstanceDart =
    int Function(
      Pointer<_Guid>,
      Pointer<Void>,
      int,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );

typedef _ReleaseNative = Uint32 Function(Pointer<Void>);
typedef _ReleaseDart = int Function(Pointer<Void>);
typedef _CreateStreamNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CreateStreamDart = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CreateDecoderFromStreamNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Int32,
      Pointer<Pointer<Void>>,
    );
typedef _CreateDecoderFromStreamDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _CreateFormatConverterNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CreateFormatConverterDart =
    int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _StreamInitializeFromMemoryNative =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _StreamInitializeFromMemoryDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _DecoderGetFrameNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _DecoderGetFrameDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _ConverterInitializeNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_Guid>,
      Int32,
      Pointer<Void>,
      Double,
      Int32,
    );
typedef _ConverterInitializeDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_Guid>,
      int,
      Pointer<Void>,
      double,
      int,
    );
typedef _SourceGetSizeNative =
    Int32 Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _SourceGetSizeDart =
    int Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _SourceCopyPixelsNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Uint8>,
    );
typedef _SourceCopyPixelsDart =
    int Function(Pointer<Void>, Pointer<Void>, int, int, Pointer<Uint8>);

/// Set `WIC_DEBUG=1` to trace why a decode declined.
final bool _debug = Platform.environment['WIC_DEBUG'] == '1';

void _trace(String step, [int? hr]) {
  if (!_debug) return;
  // ignore: avoid_print
  print('[wic] $step hr=${hr == null ? '-' : hr.toRadixString(16)}');
}

class _Bindings {
  _Bindings(this.coInitializeEx, this.coUninitialize, this.coCreateInstance);

  final _CoInitializeExDart coInitializeEx;
  final _CoUninitializeDart coUninitialize;
  final _CoCreateInstanceDart coCreateInstance;
}

_Bindings? _bindings;
bool _unavailable = false;

_Bindings? _load() {
  if (_bindings != null || _unavailable) return _bindings;
  if (!Platform.isWindows) {
    _unavailable = true;
    return null;
  }
  try {
    final ole32 = DynamicLibrary.open('ole32.dll');
    _bindings = _Bindings(
      ole32.lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
        'CoInitializeEx',
      ),
      ole32.lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
        'CoUninitialize',
      ),
      ole32.lookupFunction<_CoCreateInstanceNative, _CoCreateInstanceDart>(
        'CoCreateInstance',
      ),
    );
  } catch (_) {
    _unavailable = true;
    return null;
  }
  return _bindings;
}

/// Reads vtable slot [index] of the COM object at [object].
///
/// Dart refuses `cast<NativeFunction<T>>` when `T` is a type variable, so the
/// slot stays opaque here and each accessor below names a concrete signature.
Pointer<Void> _slot(Pointer<Void> object, int index) {
  final vtable = object.cast<Pointer<Void>>().value.cast<Pointer<Void>>();
  return vtable[index];
}

_ReleaseDart _releaseFn(Pointer<Void> object) => _slot(
  object,
  _vtableRelease,
).cast<NativeFunction<_ReleaseNative>>().asFunction<_ReleaseDart>();

_CreateStreamDart _createStreamFn(Pointer<Void> object) => _slot(
  object,
  _factoryCreateStream,
).cast<NativeFunction<_CreateStreamNative>>().asFunction<_CreateStreamDart>();

_StreamInitializeFromMemoryDart _streamInitializeFn(Pointer<Void> object) =>
    _slot(object, _streamInitializeFromMemory)
        .cast<NativeFunction<_StreamInitializeFromMemoryNative>>()
        .asFunction<_StreamInitializeFromMemoryDart>();

_CreateDecoderFromStreamDart _createDecoderFromStreamFn(Pointer<Void> object) =>
    _slot(object, _factoryCreateDecoderFromStream)
        .cast<NativeFunction<_CreateDecoderFromStreamNative>>()
        .asFunction<_CreateDecoderFromStreamDart>();

_CreateFormatConverterDart _createFormatConverterFn(Pointer<Void> object) =>
    _slot(object, _factoryCreateFormatConverter)
        .cast<NativeFunction<_CreateFormatConverterNative>>()
        .asFunction<_CreateFormatConverterDart>();

_DecoderGetFrameDart _getFrameFn(Pointer<Void> object) =>
    _slot(object, _decoderGetFrame)
        .cast<NativeFunction<_DecoderGetFrameNative>>()
        .asFunction<_DecoderGetFrameDart>();

_ConverterInitializeDart _converterInitializeFn(Pointer<Void> object) =>
    _slot(object, _converterInitialize)
        .cast<NativeFunction<_ConverterInitializeNative>>()
        .asFunction<_ConverterInitializeDart>();

_GetPixelFormatDart _getPixelFormatFn(Pointer<Void> object) =>
    _slot(object, _sourceGetPixelFormat)
        .cast<NativeFunction<_GetPixelFormatNative>>()
        .asFunction<_GetPixelFormatDart>();

_SourceGetSizeDart _getSizeFn(Pointer<Void> object) => _slot(
  object,
  _sourceGetSize,
).cast<NativeFunction<_SourceGetSizeNative>>().asFunction<_SourceGetSizeDart>();

_SourceCopyPixelsDart _copyPixelsFn(Pointer<Void> object) =>
    _slot(object, _sourceCopyPixels)
        .cast<NativeFunction<_SourceCopyPixelsNative>>()
        .asFunction<_SourceCopyPixelsDart>();

void _writeGuid(Pointer<_Guid> target, List<int> parts) {
  target.ref
    ..data1 = parts[0]
    ..data2 = parts[1]
    ..data3 = parts[2];
  for (var i = 0; i < 8; i++) {
    target.ref.data4[i] = parts[3 + i];
  }
}

void _releaseObject(Pointer<Void> object) {
  if (object == nullptr) return;
  _releaseFn(object)(object);
}

/// Whether COM could be bound on this host. Tests use it to tell "no COM" from
/// "COM present but the AVIF codec extension is missing".
bool get isSystemAvifAvailable => _load() != null;

/// The ISO-BMFF brands this fallback accepts. Other formats keep the engine's
/// original failure instead of silently decoding through a second path.
const List<String> _avifBrands = ['avif', 'avis'];

/// Whether [bytes] starts with an ISO-BMFF `ftyp` box carrying an AVIF brand.
bool isAvifContainer(Uint8List bytes) {
  if (bytes.length < 12) return false;
  for (var i = 0; i < 4; i++) {
    if (bytes[4 + i] != 'ftyp'.codeUnitAt(i)) return false;
  }
  final brand = String.fromCharCodes(bytes.sublist(8, 12));
  return _avifBrands.contains(brand);
}

/// Converts WIC's BGRA bytes into the RGBA order the rest of the app expects.
Uint8List bgraToRgba(Uint8List bgra) {
  final rgba = Uint8List.fromList(bgra);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final blue = rgba[i];
    rgba[i] = rgba[i + 2];
    rgba[i + 2] = blue;
  }
  return rgba;
}

/// Decodes [bytes] through WIC, or returns null when COM is unavailable, the
/// payload is not AVIF, the host has no AVIF codec, or any step fails.
({Uint8List rgba, int width, int height})? decodeAvifWithWic(Uint8List bytes) {
  if (!isAvifContainer(bytes)) return null;
  final api = _load();
  if (api == null) return null;

  final hresult = api.coInitializeEx(nullptr, _coinitApartmentThreaded);
  // HRESULTs arrive as signed 32-bit values; compare the unsigned form so the
  // 0x8xxxxxxx codes match their constants.
  final code = hresult & 0xFFFFFFFF;
  // RPC_E_CHANGED_MODE means another apartment already initialised COM on this
  // thread; that is usable, but it owns the uninitialise.
  final ownsCom = code == _sicOk || code == _sfcOk;
  if (!ownsCom && code != _rpcEChangedMode) {
    _trace('CoInitializeEx', code);
    return null;
  }
  _trace('CoInitializeEx ok, owns=$ownsCom');

  Pointer<Void> factory = nullptr;
  Pointer<Void> stream = nullptr;
  Pointer<Void> decoder = nullptr;
  Pointer<Void> frame = nullptr;
  Pointer<Void> converter = nullptr;
  Pointer<Uint8> input = nullptr;
  Pointer<Uint8> pixels = nullptr;
  try {
    factory = _createFactory(api);
    if (factory == nullptr) return null;
    _trace('factory');

    input = malloc<Uint8>(bytes.length);
    input.asTypedList(bytes.length).setAll(0, bytes);

    stream = _createStream(factory, input, bytes.length);
    if (stream == nullptr) return null;
    _trace('stream');

    decoder = _createDecoder(factory, stream);
    if (decoder == nullptr) return null;
    _trace('decoder');

    frame = _getFrame(decoder);
    if (frame == nullptr) return null;
    _trace('frame');

    converter = _createConverter(factory);
    if (converter == nullptr) return null;
    _trace('converter');

    final formatGuid = calloc<_Guid>();
    try {
      _writeGuid(formatGuid, _pixelFormat32bppBgra);
      final hr = _converterInitializeFn(converter)(
        converter,
        frame,
        formatGuid,
        _wicBitmapDitherTypeNone,
        nullptr,
        0,
        _wicBitmapPaletteTypeCustom,
      );
      if (hr < 0) {
        _trace('converterInitialize', hr);
        return null;
      }
      _trace('converted');
    } finally {
      calloc.free(formatGuid);
    }

    final size = calloc<Uint32>(2);
    int width;
    int height;
    try {
      final hr = _getSizeFn(converter)(converter, size, size + 1);
      if (hr < 0) {
        _trace('getSize', hr);
        return null;
      }
      width = size[0];
      height = size[1];
    } finally {
      calloc.free(size);
    }
    if (width <= 0 || height <= 0) return null;
    _trace('size $width x $height');

    final pf = calloc<_Guid>();
    try {
      final pfHr = _getPixelFormatFn(converter)(converter, pf);
      _trace(
        'pixelFormat hr=$pfHr '
        '${pf.ref.data1.toRadixString(16).padLeft(8, '0')}-'
        '${pf.ref.data2.toRadixString(16).padLeft(4, '0')}-'
        '${pf.ref.data3.toRadixString(16).padLeft(4, '0')}',
      );
    } finally {
      calloc.free(pf);
    }

    final byteLength = width * height * 4;
    pixels = malloc<Uint8>(byteLength);
    // A null rect asks for the whole image, but the AVIF codec behind WIC
    // rejects that, so an explicit full-surface rect is always passed.
    final rect = calloc<_WicRect>();
    final int copyHr;
    try {
      rect.ref
        ..left = 0
        ..top = 0
        ..width = width
        ..height = height;
      copyHr = _copyPixelsFn(converter)(
        converter,
        rect.cast<Void>(),
        width * 4,
        byteLength,
        pixels,
      );
    } finally {
      calloc.free(rect);
    }
    if (copyHr < 0) {
      _trace('copyPixels', copyHr);
      return null;
    }
    _trace('copied ${width}x$height');

    return (
      rgba: bgraToRgba(pixels.asTypedList(byteLength)),
      width: width,
      height: height,
    );
  } catch (_) {
    return null;
  } finally {
    _releaseObject(converter);
    _releaseObject(frame);
    _releaseObject(decoder);
    _releaseObject(stream);
    _releaseObject(factory);
    if (input != nullptr) malloc.free(input);
    if (pixels != nullptr) malloc.free(pixels);
    if (ownsCom) api.coUninitialize();
  }
}

Pointer<Void> _createFactory(_Bindings api) {
  final clsid = calloc<_Guid>();
  final iid = calloc<_Guid>();
  final out = calloc<Pointer<Void>>();
  try {
    _writeGuid(clsid, _clsidWicImagingFactory);
    _writeGuid(iid, _iidWicImagingFactory);
    final hr = api.coCreateInstance(
      clsid,
      nullptr,
      _clsctxInprocServer,
      iid,
      out,
    );
    if (hr < 0) {
      _trace('CoCreateInstance', hr);
      return nullptr;
    }
    return out.value;
  } finally {
    calloc.free(clsid);
    calloc.free(iid);
    calloc.free(out);
  }
}

Pointer<Void> _createStream(
  Pointer<Void> factory,
  Pointer<Uint8> buffer,
  int length,
) {
  final out = calloc<Pointer<Void>>();
  try {
    final hr = _createStreamFn(factory)(factory, out);
    if (hr < 0) {
      _trace('createStream', hr);
      return nullptr;
    }
    final stream = out.value;
    if (stream == nullptr) return nullptr;
    final initHr = _streamInitializeFn(stream)(stream, buffer, length);
    if (initHr < 0) {
      _trace('initializeFromMemory', initHr);
      _releaseObject(stream);
      return nullptr;
    }
    return stream;
  } finally {
    calloc.free(out);
  }
}

Pointer<Void> _createDecoder(Pointer<Void> factory, Pointer<Void> stream) {
  final out = calloc<Pointer<Void>>();
  try {
    final hr = _createDecoderFromStreamFn(factory)(
      factory,
      stream,
      nullptr,
      _wicDecodeMetadataCacheOnDemand,
      out,
    );
    if (hr < 0) return nullptr;
    return out.value;
  } finally {
    calloc.free(out);
  }
}

Pointer<Void> _getFrame(Pointer<Void> decoder) {
  final out = calloc<Pointer<Void>>();
  try {
    final hr = _getFrameFn(decoder)(decoder, 0, out);
    if (hr < 0) return nullptr;
    return out.value;
  } finally {
    calloc.free(out);
  }
}

Pointer<Void> _createConverter(Pointer<Void> factory) {
  final out = calloc<Pointer<Void>>();
  try {
    final hr = _createFormatConverterFn(factory)(factory, out);
    if (hr < 0) return nullptr;
    return out.value;
  } finally {
    calloc.free(out);
  }
}

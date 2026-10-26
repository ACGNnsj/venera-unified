import 'dart:async';
import 'dart:collection';

import 'package:venera_unified/features/comic_source/comic_source_api.dart'
    show ComicThumbnailLoader;
import 'package:venera_unified/foundation/res.dart';
import 'package:venera_unified/foundation/operation_failure.dart';
import 'package:venera_unified/network/request_scope.dart';

/// A single comic's cursor sequence; the host retains each accepted read.
class ComicThumbnailPages {
  ComicThumbnailPages({
    required this.comicId,
    required this._load,
    required Iterable<String> initial,
    required this._canLoad,
    required this._retain,
    required void Function() this._onChanged,
  }) : _items = List.of(initial);

  final String comicId;
  final ComicThumbnailLoader? _load;
  final List<String> _items;
  final bool Function() _canLoad;
  final void Function() Function(RequestScope, Future<void>) _retain;
  void Function()? _onChanged;
  Future<void>? _pending;
  RequestScope? _scope;
  bool _loaded = false, _closed = false;
  String? _next;
  Res<void>? _failure;

  List<String> get items => UnmodifiableListView(_items);
  bool get isLoading => _pending != null;
  bool get hasMore => !_closed && _load != null && (!_loaded || _next != null);
  Res<void>? get failure => _failure;

  Future<void> loadNext() {
    if (_pending case final pending?) return pending;
    if (!hasMore || !_canLoad()) return Future.value();
    final done = Completer<void>();
    final scope = _scope = RequestScope();
    _pending = done.future;
    _failure = null;
    void Function()? release;
    // Reserve before callbacks can reenter load/close; invoke the loader later.
    try {
      release = _retain(scope, done.future);
    } catch (error, stack) {
      _failure = Res.fromException(error, stack);
      scope.cancel();
    }
    _onChanged?.call();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final result = await scope.runToCompletion(() async {
            final response = await _load!(comicId, _next);
            // Preserve a real failure even when retirement came first.
            if (response.error) _failure = Res.fromErrorRes(response);
            return response;
          });
          if (_closed || result.error) return;
          final next = result.subData;
          if (next != null && next is! String) {
            throw const FormatException('Invalid thumbnail cursor');
          }
          final items = List<String>.of(result.data);
          _items.addAll(items);
          _next = next as String?;
          _loaded = true;
        } on RequestCancelled catch (error, stack) {
          _failure ??= Res.failure(
            OperationFailure(
              message: error.toString(),
              kind: FailureKind.cancelled,
              cause: error,
              stackTrace: stack,
            ),
          );
        } catch (error, stack) {
          _failure = Res.fromException(error, stack);
        } finally {
          scope.dispose();
          _scope = null;
          _pending = null;
          try {
            release?.call();
          } finally {
            done.complete();
            _onChanged?.call();
          }
        }
      }),
    );
    return done.future;
  }

  Future<void> closeAndWait() {
    _closed = true;
    _onChanged = null;
    _scope?.cancel();
    return _pending ?? Future.value();
  }
}

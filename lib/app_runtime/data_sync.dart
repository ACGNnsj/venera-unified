import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'data_sync_transfer.dart';
import 'data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/foundation/app.dart';

/// Construction is inert. The application owns start/stop/dispose.
DataSyncController createApplicationDataSync({
  DataSyncTransfer Function()? transfer,
  DataSyncImportRecovery? importRecovery,
  DataSyncUploadRecovery? uploadRecovery,
  bool useV117WebDav = true,
}) {
  // 默认恢复 v1.17.0 的 WebDAV 方案，不要求新协议的 ETag 或内容基线。
  // RC 的上传／内容基线恢复记录和操作标记留在原处，不阻断稳定同步流程。
  final recovery = useV117WebDav
      ? null
      : importRecovery ?? createDataSyncImportRecovery();
  final defaultTransfer = !useV117WebDav && transfer == null
      ? createDataSyncTransfer(importRecovery: recovery)
      : null;
  return DataSyncController(
    useV117WebDav: useV117WebDav,
    preferences: createAppSyncPreferences(appdata),
    transfer:
        transfer ??
        () => useV117WebDav ? createV117DataSyncTransfer() : defaultTransfer!,
    importRecovery: recovery,
    uploadRecovery: useV117WebDav ? null : uploadRecovery ?? defaultTransfer,
    content: useV117WebDav ? null : ApplicationDataSyncContent(),
    ownership: SqliteDataSyncOwnership(() => App.dataPath),
    saveSettings: () => appdata.saveData(false),
    persistImplicit: appdata.writeImplicitData,
    observeChanges: _observeApplicationChanges,
  );
}

void Function() _observeApplicationChanges(void Function() changed) {
  final favorites = LocalFavoritesManager();
  final sources = ComicSourceManager();
  favorites.addListener(changed);
  try {
    sources.addListener(changed);
    appdata.registerSyncDataRequestHandler(changed);
  } catch (_) {
    favorites.removeListener(changed);
    sources.removeListener(changed);
    rethrow;
  }
  return () {
    appdata.registerSyncDataRequestHandler(null);
    favorites.removeListener(changed);
    sources.removeListener(changed);
  };
}

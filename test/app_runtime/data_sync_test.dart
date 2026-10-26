import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/app_runtime/data_sync.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/sync/data_sync_transfer.dart';
import 'package:venera_unified/network/request_scope.dart';
import 'package:venera_unified/network/webdav.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';

void main() {
  test(
    'default application sync uses v1.17 scheduling without reading RC evidence',
    () async {
      final root = Directory.systemTemp.createTempSync('app-v117-sync-');
      final previousConnection = appdata.settings['webdav'];
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      App.dataPath = root.path;
      appdata.settings['webdav'] = ['https://example.invalid', '', ''];
      final marker = {'id': 'preserved-rc-operation', 'version': 4};
      appdata.implicitData
        ..clear()
        ..addAll({
          'webdavSyncMode': 'realtime',
          'webdavSyncPending': false,
          'webdavSyncOperation': marker,
        });
      final evidence = File('${root.path}/.data-sync-upload.sqlite')
        ..writeAsStringSync('RC upload evidence');
      final content = File('${root.path}/.data-sync-content.sqlite')
        ..writeAsStringSync('RC content evidence');
      final transfer = _V117Transfer();
      final controller = createApplicationDataSync(transfer: () => transfer);
      final competingTransfer = _V117Transfer();
      final competing = createApplicationDataSync(
        transfer: () => competingTransfer,
      );
      try {
        controller.start();
        await controller.waitForDownload();
        expect(transfer.downloads, 1);
        expect(controller.lastError, isNull);
        expect(appdata.implicitData['webdavSyncOperation'], marker);
        controller.stop();
        expect((await controller.uploadData()).success, isTrue);
        expect(transfer.uploads, 1);
        expect(transfer.operationIds, everyElement(isNull));
        expect(appdata.implicitData['webdavSyncOperation'], marker);
        expect(evidence.readAsStringSync(), 'RC upload evidence');
        expect(content.readAsStringSync(), 'RC content evidence');
        final blocked = await competing.uploadData();
        expect(blocked.error, isTrue);
        expect(blocked.errorMessage, contains('locked'));
        expect(competingTransfer.uploads, 0);
        await controller.closeAndWait();
        expect((await competing.uploadData()).success, isTrue);
        expect(competingTransfer.uploads, 1);
      } finally {
        await controller.closeAndWait();
        await competing.closeAndWait();
        await appdata.saveData(false);
        appdata.settings['webdav'] = previousConnection;
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'application controller observes while stopped and releases on dispose',
    () async {
      final root = Directory.systemTemp.createTempSync('app-sync-owner-');
      final previousConnection = appdata.settings['webdav'];
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      App.dataPath = root.path;
      appdata.settings['webdav'] = ['https://example.com', '', ''];
      appdata.implicitData['webdavSyncMode'] = 'manual';
      appdata.implicitData['webdavSyncPending'] = false;
      final controller = createApplicationDataSync();
      final other = createApplicationDataSync();
      expect(controller, isNot(same(other)));
      await other.closeAndWait();
      try {
        await appdata.saveData();
        expect(controller.hasPendingChanges, isFalse);
        controller.start();
        controller.start();
        await appdata.saveData();
        expect(controller.hasPendingChanges, isTrue);
        appdata.implicitData['webdavSyncPending'] = false;
        controller.stop();
        ComicSourceManager().notifyStateChange();
        expect(controller.hasPendingChanges, isTrue);
        appdata.implicitData['webdavSyncPending'] = false;
        await controller.closeAndWait();
        ComicSourceManager().notifyStateChange();
        await appdata.saveData();
        expect(appdata.implicitData['webdavSyncPending'], isFalse);
      } finally {
        await controller.closeAndWait();
        await appdata.saveData(false);
        appdata.settings['webdav'] = previousConnection;
        appdata.implicitData.clear();
        appdata.implicitData.addAll(previousImplicit);
        root.deleteSync(recursive: true);
      }
    },
  );
}

class _V117Transfer implements DataSyncTransfer {
  int uploads = 0;
  int downloads = 0;
  final operationIds = <String?>[];

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) async {
    uploads++;
    operationIds.add(syncOperationId);
  }

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    bool force = false,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async {
    downloads++;
    operationIds.add(syncOperationId);
    return false;
  }
}

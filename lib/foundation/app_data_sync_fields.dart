/// Fields retained locally by application-data imports. Keep content comparison
/// and import policy together so transport bookkeeping cannot create dirty data.
const appDataLocalFields = {
  'proxy',
  'authorizationRequired',
  'customImageProcessing',
  'webdav',
  'webdavProxyEnabled',
  'backupWebdav',
  'backupWebdavPath',
  'webdavComicLibrary',
  'webdavComicLibraryPath',
  'disableSyncFields',
  'deviceId',
  'lastSyncTime',
  ...appDataDeviceOnlyFields,
};

/// Native registrations must not travel in portable backups or WebDAV uploads.
const appDataDeviceOnlyFields = {
  'windowsWindowHotkey',
  'appLauncherIcon',
  // Shortcuts follow the machine: modifiers differ between macOS and the
  // rest, and a binding free on one PC may be taken on another.
  'keyboardShortcuts',
};

const appDataOptionalArchiveFields = {'backupWebdav', 'backupWebdavPath'};

List<String> splitAppDataFields(String value) => value
    .split(',')
    .map((field) => field.trim())
    .where((field) => field.isNotEmpty)
    .toList();

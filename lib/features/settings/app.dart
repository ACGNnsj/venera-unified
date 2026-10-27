import 'package:venera_unified/foundation/app_sync_preferences.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/button.dart';
import 'package:venera_unified/components/pop_up_widget.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/components/window_hotkey_scope.dart';
import 'package:venera_unified/features/settings/window_hotkey_setting.dart';
import 'package:venera_unified/features/settings/launcher_icon_settings.dart';
import 'package:venera_unified/features/settings/setting_components.dart';
import 'package:venera_unified/features/settings/app_controls.dart';
import 'package:venera_unified/features/settings/local_storage_settings.dart';
import 'package:venera_unified/features/settings/settings_task_presenter.dart';
import 'package:venera_unified/features/settings/data_sync_schedule_fields.dart';
import 'package:venera_unified/features/settings/webdav_settings.dart';
import 'package:venera_unified/features/settings/webdav_qr_payload.dart';
import 'package:venera_unified/features/settings/webdav_sync_qr.dart';
import 'package:venera_unified/features/sync/sync.dart';
import 'package:venera_unified/features/webdav_library/webdav_library.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/cache_manager.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/file_interaction.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  final _tasks = SettingsTaskPresenter();
  @override
  Widget build(BuildContext context) {
    final hotkey = WindowHotkeyScope.maybeOf(context);
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("App".tl)),
        SettingPartTitle(title: "Data".tl, icon: Icons.storage),
        const LocalStorageSettings().toSliver(),
        ListTile(
          title: Text("Cache Size".tl),
          subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
        ).toSliver(),
        CallbackSetting(
          title: "Clear Cache".tl,
          actionTitle: "Clear".tl,
          callback: () async {
            await _tasks.run(
              context,
              task: (_) async {
                await CacheManager().clear();
                return null;
              },
              errorMessage: "Error".tl,
              successMessage: "Cache cleared".tl,
              onSuccess: () => setState(() {}),
            );
          },
        ).toSliver(),
        const CacheLimitSetting().toSliver(),
        const CacheRetentionSetting().toSliver(),
        const HistoryRetentionSetting().toSliver(),
        CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            await _tasks.run(
              context,
              task: (operation) async {
                await operation.useTemporaryFile(
                  cacheDirectory: Directory(App.cachePath),
                  filename: 'data.venera',
                  prepare: (file) async {
                    await exportAppData(sync: false, destination: file);
                  },
                  consume: (file) => saveFile(
                    operation: operation,
                    filename: 'data.venera',
                    file: file,
                    checkStop: operation.checkActive,
                  ),
                );
                return null;
              },
              errorMessage: "Error".tl,
            );
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            await _tasks.run(
              context,
              task: (operation) async {
                final file = await operation.pickFile(
                  () => selectFile(
                    ext: ['venera', 'picadata'],
                    checkStop: operation.checkActive,
                  ),
                );
                if (file == null) return null;
                return operation.useFileCopy(
                  file,
                  cacheDirectory: Directory(App.cachePath),
                  consume: (cacheFile) async {
                    try {
                      if (file.name.endsWith('picadata')) {
                        await importPicaData(cacheFile);
                      } else {
                        await importAppData(cacheFile);
                      }
                    } finally {
                      appNavigation.forceRebuild();
                    }
                    return null;
                  },
                );
              },
              errorMessage: "Failed to import data".tl,
            );
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Data Sync".tl,
          callback: () async {
            showPopUpWidget(context, const _WebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Comic Archive Backup".tl,
          subtitle: "This is only used for CBZ archive backup and restore.".tl,
          callback: () async {
            showPopUpWidget(context, const BackupWebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "WebDAV Comic Library".tl,
          subtitle:
              "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                  .tl,
          callback: () async {
            showPopUpWidget(
              context,
              WebDavComicLibrarySetting(WebDavLibraryScope.of(context)),
            );
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        SettingPartTitle(title: "User".tl, icon: Icons.person_outline),
        SelectSetting.preference(
          title: "Language".tl,
          preference: AppPreferences.language,
          optionTranslation: const {
            "system": "System",
            "zh-CN": "简体中文",
            "zh-TW": "繁體中文",
            "en-US": "English",
          },
          onChanged: () {
            appNavigation.forceRebuild();
          },
        ).toSliver(),
        if (!App.isLinux) const AuthorizationRequiredSetting().toSliver(),
        if (App.isWindows) ...[
          SettingPartTitle(title: 'Window'.tl, icon: Icons.desktop_windows),
          if (hotkey != null)
            WindowHotkeySetting(controller: hotkey).toSliver(),
          SwitchSetting.preference(
            title: 'Minimize to tray'.tl,
            subtitle:
                'Closing the window hides it into the tray instead of exiting.'
                    .tl,
            preference: AppPreferences.minimizeToTray,
          ).toSliver(),
        ],
        if (LauncherIconService.isSupported)
          ListTile(
            title: Text("App Icon".tl),
            subtitle: Text(
              LauncherIconService.isWindowIconOnly
                  ? "Choose the window and taskbar icon".tl
                  : "Choose the home screen icon".tl,
            ),
            leading: const Icon(Icons.apps_outlined),
            trailing: const Icon(Icons.arrow_right),
            onTap: () {
              context.to(() => const LauncherIconSettings());
            },
          ).toSliver(),
      ],
    );
  }
}

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";

  DataSyncMode syncMode = DataSyncMode.realtime;
  int syncInterval = 30;
  late final TextEditingController urlController;
  late final TextEditingController userController;
  late final TextEditingController passController;
  late final TextEditingController fieldsController;

  bool isTesting = false;
  bool upload = true;

  @override
  void initState() {
    super.initState();
    final config = createAppSyncPreferences(appdata).configuration;
    if (config.excludedFields.trim().isNotEmpty) {
      disableSync = config.excludedFields;
    }
    final connection = config.connection;
    if (connection != null && !connection.isEmpty) {
      url = connection.url;
      user = connection.user;
      pass = connection.password;
      syncMode = config.mode;
    }
    syncInterval = config.intervalMinutes;
    urlController = TextEditingController(text: url);
    userController = TextEditingController(text: user);
    passController = TextEditingController(text: pass);
    fieldsController = TextEditingController(text: disableSync);
  }

  @override
  void dispose() {
    urlController.dispose();
    userController.dispose();
    passController.dispose();
    fieldsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: AbsorbPointer(
        absorbing: isTesting,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "URL",
                  hintText: "A valid WebDav directory URL".tl,
                  border: OutlineInputBorder(),
                ),
                controller: urlController,
                onChanged: (value) => url = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Username".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: userController,
                onChanged: (value) => user = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Password".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: passController,
                onChanged: (value) => pass = value,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.qr_code_2),
                      label: Text("Config QR code".tl),
                      onPressed: showQrCode,
                    ),
                  ),
                  if (App.isMobile) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code_scanner),
                        label: Text("Scan config".tl),
                        onPressed: scanQrCode,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Skip Setting Fields (Optional)".tl,
                  hintText: "field0, field1, field2, ...",
                  hintStyle: TextStyle(color: Theme.of(context).hintColor),
                  border: OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(Icons.help_outline),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text("Skip Setting Fields".tl),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "When sync data, skip certain setting fields, which means these won't be uploaded / override."
                                    .tl,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      "See source code for available fields."
                                          .tl,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      icon: const Icon(Icons.open_in_new),
                                      onPressed: () {
                                        launchUrlString(
                                          "https://github.com/CyrilPeng/venera-next/blob/main/lib/foundation/appdata.dart#L138",
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                controller: fieldsController,
                onChanged: (value) => disableSync = value,
              ),
              const SizedBox(height: 12),
              DataSyncScheduleFields(
                mode: syncMode,
                minutes: syncInterval,
                onModeChanged: (value) => setState(() => syncMode = value),
                onIntervalChanged: (value) =>
                    setState(() => syncInterval = value),
              ),
              const SizedBox(height: 12),
              if (syncMode != DataSyncMode.manual) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Initial sync'.tl),
                ),
                RadioGroup<bool>(
                  groupValue: upload,
                  onChanged: (value) {
                    setState(() {
                      upload = value ?? upload;
                    });
                  },
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        title: Text('Upload'.tl),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: Text('Download'.tl),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: syncMode != DataSyncMode.manual
                    ? Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "Once the operation is successful, app will automatically sync data with the server."
                                    .tl,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      isLoading: isTesting,
                      onPressed: testConnection,
                      child: Text("Test Connection".tl),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: Button.filled(
                  isLoading: isTesting,
                  onPressed: () async {
                    if (isTesting) return;
                    setState(() {
                      isTesting = true;
                    });
                    final clear =
                        url.trim().isEmpty &&
                        user.trim().isEmpty &&
                        pass.trim().isEmpty;
                    final testResult = await DataSyncScope.of(context)
                        .configure(
                          config: clear ? [] : [url.trim(), user, pass],
                          excludedFields: disableSync,
                          syncMode: syncMode,
                          minutes: syncInterval,
                          initialUpload: upload,
                        );
                    if (!context.mounted) return;
                    setState(() => isTesting = false);
                    if (testResult.error) {
                      context.showMessage(message: testResult.errorMessage!);
                      context.showMessage(message: "Saved Failed".tl);
                    } else {
                      context.showMessage(message: "Saved".tl);
                      appNavigation.rootPop();
                    }
                  },
                  child: Text("Continue".tl),
                ),
              ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  BackupConfig get currentConfig =>
      BackupConfig(url: url, user: user, pass: pass, remotePath: '/');

  WebdavSyncQrPayload get currentPayload => WebdavSyncQrPayload(
    url: url,
    user: user,
    pass: pass,
    excludedFields: disableSync,
    mode: syncMode.name,
    intervalMinutes: syncInterval,
  );

  void showQrCode() {
    showWebdavSyncQrDialog(context, currentPayload);
  }

  Future<void> scanQrCode() async {
    final payload = await context.to<WebdavSyncQrPayload>(
      () => const WebdavSyncQrScannerPage(),
    );
    if (!mounted || payload == null) return;
    setState(() {
      url = payload.url;
      user = payload.user;
      pass = payload.pass;
      disableSync = payload.excludedFields;
      syncMode = DataSyncMode.values.byName(payload.mode);
      syncInterval = payload.intervalMinutes;
      urlController.text = url;
      userController.text = user;
      passController.text = pass;
      fieldsController.text = disableSync;
    });
  }

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.instance.testConnection(
      currentConfig,
    );
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }
}

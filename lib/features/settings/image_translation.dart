import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/button.dart';
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/components/settings_save_state.dart';
import 'package:venera_unified/features/settings/setting_components.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/image_translation/llm_translator.dart';
import 'package:venera_unified/foundation/image_translation/translation_config.dart';
import 'package:venera_unified/foundation/image_translation/translation_models.dart';
import 'package:venera_unified/foundation/image_translation/translation_service.dart';
import 'package:venera_unified/foundation/image_translation/translation_sources.dart';
import 'package:venera_unified/foundation/image_translation/translation_targets.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

/// Image translation settings page (opened from Reading settings).
///
/// Four sections mirroring the translation foundation APIs, styled after
/// [UpscaleSetting]: global language pair + text-removal mode
/// ([TranslationConfig]), the LLM provider list ([LlmProviderStore]), the
/// per-comic glossary ([ImageTranslationService]), and OCR model management
/// ([TranslationModels] + [TranslationModelStore]).
///
/// Only the global language pair is edited here; per-comic overrides keep
/// living in the reader. English source strings only, translation.json
/// entries are left to the lead.
class ImageTranslationSettings extends StatefulWidget {
  const ImageTranslationSettings({super.key});

  @override
  State<ImageTranslationSettings> createState() =>
      _ImageTranslationSettingsState();
}

class _ImageTranslationSettingsState
    extends SettingsSaveState<ImageTranslationSettings> {
  final _extraComicKeys = <String>[];
  final _cidController = TextEditingController();
  final _sourceKeyController = TextEditingController();
  String? _openerError;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ImageTranslationService.instance.addListener(_refresh);
    TranslationModelStore.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    ImageTranslationService.instance.removeListener(_refresh);
    TranslationModelStore.instance.removeListener(_refresh);
    _cidController.dispose();
    _sourceKeyController.dispose();
    super.dispose();
  }

  Map<String, String> _sourceOptions() {
    final options = <String, String>{'auto': 'Auto detect'.tl};
    TranslationSources.builtIn.forEach((code, label) {
      options[code] = label.tl;
    });
    for (final custom in TranslationSources.custom) {
      options[custom.code] = custom.name;
    }
    final current = TranslationConfig.global.sourceLang;
    options.putIfAbsent(current, () => current);
    return options;
  }

  Map<String, String> _targetOptions() {
    final options = <String, String>{};
    TranslationTargets.builtIn.forEach((code, entry) {
      options[code] = entry.label.tl;
    });
    for (final custom in TranslationTargets.custom) {
      options[custom.code] = custom.name;
    }
    final current = TranslationConfig.global.targetLang;
    options.putIfAbsent(current, () => current);
    return options;
  }

  Map<String, String> _inpaintOptions() {
    final options = <String, String>{
      InpaintMode.smart.name: 'Smart erase'.tl,
      InpaintMode.patch.name: 'Opaque patch'.tl,
    };
    final current = TranslationConfig.global.mode.name;
    options.putIfAbsent(current, () => current);
    return options;
  }

  String _describeProvider(LlmProvider provider) {
    if (provider.isPublicFree) return 'Public free service'.tl;
    if (provider.isCustomScript) return 'Custom script'.tl;
    final model = provider.model.trim();
    final url = provider.url.trim();
    if (model.isEmpty) {
      return url.isEmpty ? 'Not configured'.tl : url;
    }
    return url.isEmpty ? model : '$model · $url';
  }

  Future<void> _addProvider() async {
    await showDialog(
      context: context,
      builder: (_) => const _ProviderDialog(),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editProvider(LlmProvider provider) async {
    await showDialog(
      context: context,
      builder: (_) => _ProviderDialog(existing: provider),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteProvider(LlmProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: 'Delete provider'.tl,
        content: Text(
          'Delete this provider?'.tl,
        ).paddingHorizontal(16).fixWidth(double.infinity),
        actions: [
          Button.filled(onPressed: context.pop, child: Text('Cancel'.tl)),
          Button.filled(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      LlmProviderStore.remove(provider.id);
      if (mounted) setState(() {});
    }
  }

  void _openComic() {
    final cid = _cidController.text.trim();
    final sourceKey = _sourceKeyController.text.trim();
    if (cid.isEmpty) {
      setState(() => _openerError = 'Comic ID is required'.tl);
      return;
    }
    final key = "$cid@${sourceKey.isEmpty ? 'local' : sourceKey}";
    setState(() {
      _openerError = null;
      if (!_extraComicKeys.contains(key) &&
          !ImageTranslationService.enabledComicKeys.contains(key)) {
        _extraComicKeys.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final configured = LlmTranslator.isConfigured;
    final sourceLang = TranslationConfig.global.sourceLang;
    final modelsReady = TranslationModels.isReadyFor(sourceLang);
    final providers = LlmProviderStore.providers;
    final activeId = LlmProviderStore.activeId;
    final requiredIds = TranslationModels.requiredFor(
      sourceLang,
    ).map((c) => c.id).toSet();
    final comicKeys = <String>{
      ...ImageTranslationService.enabledComicKeys,
      ..._extraComicKeys,
    }.toList()
      ..sort();
    return protectSettings(
      SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Image Translation'.tl)),
          settingsSaveStatus.toSliver(),
          if (!configured)
            ListTile(
              leading: const Icon(Icons.warning_amber),
              title: Text('Translation endpoint not configured'.tl),
              subtitle: Text(
                'Add an OpenAI-compatible provider or use the public free service.'
                    .tl,
              ),
            ).toSliver(),
          if (configured && !modelsReady)
            ListTile(
              leading: const Icon(Icons.warning_amber),
              title: Text('OCR models missing'.tl),
              subtitle: Text(
                'Download the required models below before translating.'.tl,
              ),
            ).toSliver(),
          SettingPartTitle(
            title: 'Language & text removal'.tl,
            icon: Icons.translate,
          ),
          SelectSetting(
            title: 'Source language'.tl,
            settingKey: TranslationConfig.sourceKeyName,
            optionTranslation: _sourceOptions(),
          ).toSliver(),
          SelectSetting(
            title: 'Target language'.tl,
            settingKey: TranslationConfig.targetKeyName,
            optionTranslation: _targetOptions(),
          ).toSliver(),
          SelectSetting(
            title: 'Text removal'.tl,
            settingKey: TranslationConfig.inpaintKeyName,
            optionTranslation: _inpaintOptions(),
          ).toSliver(),
          SettingPartTitle(
            title: 'Translation providers'.tl,
            icon: Icons.cloud,
          ),
          if (providers.isEmpty)
            ListTile(
              title: Text('No providers yet'.tl),
              subtitle: Text(
                'Add an OpenAI-compatible endpoint or the public free service.'
                    .tl,
              ),
            ).toSliver(),
          for (final provider in providers)
            ListTile(
              key: ValueKey('provider-${provider.id}'),
              title: Text(
                provider.name.isEmpty
                    ? 'Unnamed provider'.tl
                    : provider.name,
              ),
              subtitle: Text(_describeProvider(provider)),
              leading: Icon(
                provider.id == activeId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: provider.id == activeId
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit'.tl,
                    onPressed: () => _editProvider(provider),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    tooltip: 'Delete'.tl,
                    onPressed: () => _deleteProvider(provider),
                  ),
                ],
              ),
              onTap: () {
                LlmProviderStore.setActive(provider.id);
                setState(() {});
              },
            ).toSliver(),
          CallbackSetting(
            title: 'Add provider'.tl,
            callback: _addProvider,
            actionTitle: 'Add'.tl,
          ).toSliver(),
          SettingPartTitle(title: 'Glossary'.tl, icon: Icons.book),
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Open another comic'.tl,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _cidController,
                          decoration: InputDecoration(
                            labelText: 'Comic ID'.tl,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _sourceKeyController,
                          decoration: InputDecoration(
                            labelText: 'Source key'.tl,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.folder_open),
                        tooltip: 'Open'.tl,
                        onPressed: _openComic,
                      ),
                    ],
                  ),
                  if (_openerError != null)
                    Text(
                      _openerError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ).toSliver(),
          if (comicKeys.isEmpty)
            ListTile(
              title: Text('No glossaries yet'.tl),
              subtitle: Text(
                'Terms learned while translating will appear here, grouped by comic.'
                    .tl,
              ),
            ).toSliver(),
          for (final key in comicKeys) _GlossaryCard(comicKey: key).toSliver(),
          SettingPartTitle(
            title: 'Translation models'.tl,
            icon: Icons.memory,
          ),
          for (final component in TranslationModels.all)
            _ModelTile(
              component: component,
              required: requiredIds.contains(component.id),
            ).toSliver(),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1000000) {
    return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1000).toStringAsFixed(0)} KB';
}

/// Add/edit dialog for one translation provider.
class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.existing});

  final LlmProvider? existing;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late LlmProviderKind _kind;
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _script;
  List<String>? _fetched;
  bool _fetching = false;
  String? _fetchError;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _kind = existing?.kind ?? LlmProviderKind.openai;
    _name = TextEditingController(text: existing?.name ?? '');
    _url = TextEditingController(text: existing?.url ?? '');
    _key = TextEditingController(text: existing?.key ?? '');
    _model = TextEditingController(text: existing?.model ?? '');
    _script = TextEditingController(text: existing?.script ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _script.dispose();
    super.dispose();
  }

  String _kindLabel(LlmProviderKind kind) {
    return switch (kind) {
      LlmProviderKind.openai => 'OpenAI compatible'.tl,
      LlmProviderKind.publicFree => 'Public free (no setup)'.tl,
      LlmProviderKind.customScript => 'Custom script'.tl,
    };
  }

  Future<void> _fetchModels() async {
    setState(() {
      _fetching = true;
      _fetchError = null;
      _fetched = null;
    });
    try {
      final models = await LlmTranslator.fetchModels(
        url: _url.text,
        key: _key.text,
      );
      if (!mounted) return;
      setState(() {
        _fetched = models;
        _fetchError = models.isEmpty ? 'No models found'.tl : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetchError = e.toString());
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  void _save() {
    if (_kind == LlmProviderKind.openai && _url.text.trim().isEmpty) {
      setState(() => _error = 'URL is required'.tl);
      return;
    }
    if (_kind == LlmProviderKind.customScript &&
        _script.text.trim().isEmpty) {
      setState(() => _error = 'Script is required'.tl);
      return;
    }
    final provider = LlmProvider(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: _name.text.trim().isEmpty ? _kindLabel(_kind) : _name.text.trim(),
      url: _kind == LlmProviderKind.openai ? _url.text.trim() : '',
      key: _kind == LlmProviderKind.openai ? _key.text.trim() : '',
      model: _kind == LlmProviderKind.openai ? _model.text.trim() : '',
      kind: _kind,
      script: _kind == LlmProviderKind.customScript ? _script.text : '',
    );
    if (widget.existing == null) {
      LlmProviderStore.add(provider);
    } else {
      LlmProviderStore.update(provider);
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: widget.existing == null ? 'Add provider'.tl : 'Edit provider'.tl,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<LlmProviderKind>(
            value: _kind,
            isExpanded: true,
            items: [
              for (final kind in LlmProviderKind.values)
                DropdownMenuItem(value: kind, child: Text(_kindLabel(kind))),
            ],
            onChanged: (kind) {
              if (kind != null) setState(() => _kind = kind);
            },
          ),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: 'Provider name'.tl),
          ),
          if (_kind == LlmProviderKind.openai) ...[
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: 'API URL'.tl,
                hintText: 'https://host/v1',
              ),
            ),
            TextField(
              controller: _key,
              decoration: InputDecoration(labelText: 'API key'.tl),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _model,
                    decoration: InputDecoration(labelText: 'Model'.tl),
                  ),
                ),
                const SizedBox(width: 8),
                if (_fetching)
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.cloud_download),
                    tooltip: 'Fetch models'.tl,
                    onPressed: _fetchModels,
                  ),
              ],
            ),
            if (_fetchError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _fetchError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (_fetched != null && _fetched!.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final name in _fetched!.take(30))
                      ActionChip(
                        label: Text(name),
                        onPressed: () => setState(() => _model.text = name),
                      ),
                  ],
                ),
              ),
          ],
          if (_kind == LlmProviderKind.customScript)
            TextField(
              controller: _script,
              maxLines: 4,
              decoration: InputDecoration(labelText: 'Script'.tl),
            ),
          if (_error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ).paddingHorizontal(16).fixWidth(double.infinity),
      actions: [
        Button.filled(onPressed: context.pop, child: Text('Cancel'.tl)),
        const SizedBox(width: 8),
        Button.filled(onPressed: _save, child: Text('Save'.tl)),
      ],
    );
  }
}

/// Splits a stored 'cid@sourceKey' comic key. Source keys never contain '@'.
(String, String) _splitComicKey(String key) {
  final at = key.lastIndexOf('@');
  if (at < 0) return (key, 'local');
  return (key.substring(0, at), key.substring(at + 1));
}

/// Glossary editor for one comic, grouped under its 'cid@sourceKey' key.
class _GlossaryCard extends StatefulWidget {
  const _GlossaryCard({required this.comicKey});

  final String comicKey;

  @override
  State<_GlossaryCard> createState() => _GlossaryCardState();
}

class _GlossaryCardState extends State<_GlossaryCard> {
  final _source = TextEditingController();
  final _translation = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _source.dispose();
    _translation.dispose();
    super.dispose();
  }

  void _add(String cid, String sourceKey) {
    final ok = ImageTranslationService.instance.setGlossaryEntry(
      cid,
      sourceKey,
      _source.text,
      _translation.text,
    );
    setState(() {
      _error = ok ? null : 'Invalid term'.tl;
      if (ok) {
        _source.clear();
        _translation.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = ImageTranslationService.instance;
    final (cid, sourceKey) = _splitComicKey(widget.comicKey);
    final entries = service.glossaryOf(cid, sourceKey);
    final blocked = service.blockedTermsOf(cid, sourceKey);
    final errorColor = Theme.of(context).colorScheme.error;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ExpansionTile(
        title: Text(widget.comicKey),
        subtitle: Text(
          entries.length.toString() + ' terms'.tl,
        ),
        children: [
          for (final entry in entries.entries)
            ListTile(
              dense: true,
              title: Text('${entry.key} → ${entry.value}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.block),
                    tooltip: 'Delete & block'.tl,
                    onPressed: () => service.removeGlossaryEntry(
                      cid,
                      sourceKey,
                      entry.key,
                      block: true,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    tooltip: 'Delete'.tl,
                    onPressed: () => service.removeGlossaryEntry(
                      cid,
                      sourceKey,
                      entry.key,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _source,
                    decoration: InputDecoration(
                      hintText: 'Source term'.tl,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _translation,
                    decoration: InputDecoration(
                      hintText: 'Translation'.tl,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add'.tl,
                  onPressed: () => _add(cid, sourceKey),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!, style: TextStyle(color: errorColor)),
              ),
            ),
          if (blocked.isNotEmpty)
            ListTile(
              dense: true,
              title: Text('Blocked terms'.tl),
            ),
          for (final term in blocked)
            ListTile(
              dense: true,
              title: Text(term),
              trailing: TextButton(
                onPressed: () => service.unblockTerm(cid, sourceKey, term),
                child: Text('Unblock'.tl),
              ),
            ),
        ],
      ),
    );
  }
}

/// One downloadable translation component (detector / OCR model).
class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.component, required this.required});

  final ModelComponent component;
  final bool required;

  String _subtitle(ModelDownloadState state, bool installed) {
    final parts = <String>[
      _formatBytes(component.approxSizeBytes),
      installed ? 'Installed'.tl : 'Not installed'.tl,
    ];
    if (required) parts.insert(0, 'Required'.tl);
    if (state.downloading) {
      parts.add('${(state.progress * 100).toStringAsFixed(0)}%');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final store = TranslationModelStore.instance;
    final state = store.stateOf(component);
    final installed = component.isInstalled;
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: ValueKey('model-${component.id}'),
          title: Text(component.id),
          subtitle: Text(_subtitle(state, installed)),
          trailing: state.downloading
              ? IconButton(
                  icon: const Icon(Icons.cancel),
                  tooltip: 'Cancel'.tl,
                  onPressed: () => store.cancelDownload(component),
                )
              : installed
                  ? IconButton(
                      icon: const Icon(Icons.delete),
                      tooltip: 'Delete'.tl,
                      onPressed: () => store.delete(component),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Download'.tl,
                      onPressed: () => store.download(component),
                    ),
        ),
        if (state.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: LinearProgressIndicator(value: state.progress),
          ),
        if (state.error != null && !state.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(state.error!, style: TextStyle(color: errorColor)),
            ),
          ),
      ],
    );
  }
}
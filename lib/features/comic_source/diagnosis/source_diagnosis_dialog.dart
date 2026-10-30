import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';

import '../source.dart';
import 'source_diagnosis_manager.dart';
import 'source_diagnosis_models.dart';

/// Opens the manual readability diagnosis dialog for one installed source.
///
/// The dialog never starts a round on its own. A round that is already in
/// flight is joined, so closing and reopening the dialog follows the same
/// requests instead of starting a second diagnosis (A1-02, A1-07).
Future<void> showSourceDiagnosisDialog(
  BuildContext context, {
  required ComicSource source,
  SourceDiagnosisManager? manager,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SourceDiagnosisDialog(source: source, manager: manager),
  );
}

/// Manual readability diagnosis UI for a single comic source (A1).
///
/// [manager] defaults to the app-lifetime [SourceDiagnosisManager.instance].
/// Tests inject their own manager with a fake runner.
class SourceDiagnosisDialog extends StatefulWidget {
  const SourceDiagnosisDialog({super.key, required this.source, this.manager});

  final ComicSource source;

  final SourceDiagnosisManager? manager;

  @override
  State<SourceDiagnosisDialog> createState() => _SourceDiagnosisDialogState();
}

class _SourceDiagnosisDialogState extends State<SourceDiagnosisDialog> {
  late final SourceDiagnosisManager _manager;
  late final TextEditingController _comicIdController;

  bool _busyNotice = false;
  bool _staleNotice = false;
  bool _runFailed = false;
  bool _copied = false;

  String get _sourceKey => widget.source.key;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? SourceDiagnosisManager.instance;
    _comicIdController = TextEditingController();
    _manager.addListener(_onManagerChanged);
    // Follow a round that was already running before the dialog opened. This
    // must never start a second round (A1-07).
    final inFlight = _manager.inFlightOf(_sourceKey);
    if (inFlight != null) {
      _observe(inFlight);
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _comicIdController.dispose();
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _observe(Future<SourceDiagnosisReport> future) {
    future.then<void>(
      (_) {
        if (!mounted) return;
        setState(() {});
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() {
          if (error is SourceDiagnosisStaleException) {
            _staleNotice = true;
          } else {
            _runFailed = true;
          }
        });
      },
    );
  }

  void _start() {
    if (_manager.phaseOf(_sourceKey) != SourceDiagnosisPhase.idle) {
      return;
    }
    setState(() {
      _busyNotice = false;
      _staleNotice = false;
      _runFailed = false;
      _copied = false;
    });
    try {
      final future = _manager.start(
        widget.source,
        comicId: _comicIdController.text,
      );
      _observe(future);
    } on SourceDiagnosisBusyException {
      if (!mounted) return;
      setState(() => _busyNotice = true);
    }
  }

  Future<void> _copySummary(SourceDiagnosisReport report) async {
    final summary = buildSourceDiagnosisSummary(report);
    // Clipboard content must stay inside the A5-01 whitelist (A5-04).
    assertSourceDiagnosisSummaryIsPrivate(summary);
    try {
      await Clipboard.setData(ClipboardData(text: summary));
    } catch (_) {
      if (!mounted) return;
      context.showMessage(message: 'Could not copy the diagnosis summary'.tl);
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    context.showMessage(message: 'Diagnosis summary copied'.tl);
  }

  @override
  Widget build(BuildContext context) {
    final phase = _manager.phaseOf(_sourceKey);
    final progress = _manager.progressOf(_sourceKey);
    final report = _manager.lastReportOf(_sourceKey);
    final running = phase == SourceDiagnosisPhase.running;
    final settling = phase == SourceDiagnosisPhase.settling;
    final idle = phase == SourceDiagnosisPhase.idle;

    return ContentDialog(
      title: 'Diagnose readability'.tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.query_stats, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Source: @name'.tlParams({
                      'name': _maskUrls(widget.source.name),
                    }),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildDisclosure(),
            const SizedBox(height: 12),
            TextField(
              controller: _comicIdController,
              enabled: idle,
              decoration: InputDecoration(
                labelText: 'Comic ID (optional)'.tl,
                helperText:
                    'Leave empty to sample the source explore pages automatically.'
                        .tl,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _start(),
            ),
            const SizedBox(height: 16),
            if (running) _buildRunning(progress),
            if (settling) _buildSettling(),
            if (report != null && !running) _buildReport(report),
            if (idle && report == null) _buildNotStarted(),
            if (_busyNotice)
              _Notice(
                icon: Icons.hourglass_top,
                message: 'A diagnosis is already running. Try again later.'.tl,
              ),
            if (_staleNotice)
              _Notice(
                icon: Icons.change_circle_outlined,
                message:
                    'The source changed during diagnosis. The result was discarded; start a new check.'
                        .tl,
              ),
            if (_runFailed)
              _Notice(
                icon: Icons.error_outline,
                message:
                    'The diagnosis could not be completed. Try again later.'.tl,
              ),
            if (_copied)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, size: 18),
                    const SizedBox(width: 8),
                    Text('Diagnosis summary copied'.tl),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Close'.tl),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: idle ? _start : null,
          child: Text(_startLabel(phase, report)),
        ),
      ],
    );
  }

  Widget _buildDisclosure() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 20,
            color: context.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // One literal on purpose: the translation key is the whole
              // sentence, not the concatenation fragments.
              'This runs the source script and sends real network requests (up to @samples samples × 4 stages). It may use data and trigger rate limits. The remote script may have side effects that cannot be guaranteed read-only. Results only reflect the selected samples and the current network/login environment.'
                  .tlParams({'samples': SourceDiagnosisLimits.maxSamples}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRunning(SourceDiagnosisProgress? progress) {
    final rows = progress?.settled ?? const <SourceDiagnosisStageResult>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (progress != null)
          Semantics(
            liveRegion: true,
            child: Text(
              'Current stage: @stage'.tlParams({
                'stage': _stageLabel(progress.stage),
              }),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        const SizedBox(height: 8),
        for (final row in rows) _StageRow(row: row),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(_stageLabel(progress.stage))),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'You can close this dialog while the diagnosis continues in the background.'
              .tl,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildSettling() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Waiting for the previous diagnosis request to finish…'.tl,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotStarted() {
    return Text(
      'Nothing has run yet. Start a diagnosis to check this source with a few samples.'
          .tl,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  Widget _buildReport(SourceDiagnosisReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildVerdict(report),
        const SizedBox(height: 12),
        if (report.sampleTitle == null)
          Text('Sample title unavailable'.tl)
        else
          Text(
            'Sample title: @title'.tlParams({
              'title': _sanitizeSampleText(report.sampleTitle!),
            }),
          ),
        const SizedBox(height: 4),
        Text(
          report.comicIdUserProvided
              ? 'Comic ID was provided by you'.tl
              : 'Comic ID was picked automatically'.tl,
        ),
        const SizedBox(height: 4),
        Text(
          'Diagnosed at: @time'.tlParams({
            'time': _formatDiagnosedAt(report.diagnosedAt),
          }),
        ),
        const Divider(height: 24),
        Text(
          'Stage results:'.tl,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        for (final row in report.stages) _StageRow(row: row),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => _copySummary(report),
          icon: const Icon(Icons.copy, size: 18),
          label: Text('Copy diagnosis summary'.tl),
        ),
        Text(
          'Results only reflect the selected samples and the current network/login environment.'
              .tl,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildVerdict(SourceDiagnosisReport report) {
    final (icon, color, title, description) = switch (report.verdict) {
      SourceDiagnosisVerdict.readable => (
        Icons.check_circle_outline,
        context.colorScheme.primary,
        'Readable'.tl,
        'The sample passed all four stages.'.tl,
      ),
      SourceDiagnosisVerdict.failed => (
        Icons.error_outline,
        context.colorScheme.error,
        'Failed'.tl,
        'Failed at: @stage'.tlParams({
          'stage': _stageLabel(report.failedStage!),
        }),
      ),
      SourceDiagnosisVerdict.unknown => (
        Icons.help_outline,
        context.colorScheme.outline,
        'Unknown'.tl,
        'The diagnosis timed out or the environment was insufficient.'.tl,
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    title,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 4),
                Text(description),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _startLabel(
    SourceDiagnosisPhase phase,
    SourceDiagnosisReport? report,
  ) {
    if (phase == SourceDiagnosisPhase.running) {
      return 'Diagnosis in progress…'.tl;
    }
    if (phase == SourceDiagnosisPhase.settling) {
      return 'Please wait…'.tl;
    }
    return (report == null ? 'Start diagnosis' : 'Recheck').tl;
  }
}

/// Renders the A5-01 whitelist as plain text for the clipboard.
///
/// Only the source key/name, verdict, failed stage, sample title, whether the
/// comic ID was user-provided, diagnosis time, and per-stage rows are included.
/// Raw errors, URLs, headers, bodies, stacks, and full comic identities never
/// appear here (A5-01, A5-04).
String buildSourceDiagnosisSummary(SourceDiagnosisReport report) {
  final lines = <String>[
    'Diagnosis summary'.tl,
    'Source: @name'.tlParams({'name': _maskUrls(report.sourceName)}),
    'Source key: @key'.tlParams({'key': _maskUrls(report.sourceKey)}),
    'Verdict: @verdict'.tlParams({'verdict': _verdictLabel(report.verdict)}),
    if (report.failedStage != null)
      'Failed at: @stage'.tlParams({'stage': _stageLabel(report.failedStage!)}),
    if (report.sampleTitle == null)
      'Sample title unavailable'.tl
    else
      'Sample title: @title'.tlParams({
        'title': _sanitizeSampleText(report.sampleTitle!),
      }),
    report.comicIdUserProvided
        ? 'Comic ID was provided by you'.tl
        : 'Comic ID was picked automatically'.tl,
    'Diagnosed at: @time'.tlParams({
      'time': _formatDiagnosedAt(report.diagnosedAt),
    }),
    '',
    'Stage results:'.tl,
    for (final row in report.stages) _stageSummaryLine(row),
    '',
    'Results only reflect the selected samples and the current network/login environment.'
        .tl,
  ];
  return lines.join('\n');
}

/// Fails when [text] holds data outside the A5-01 whitelist.
///
/// Used on every clipboard payload before [Clipboard.setData] (A5-04). This is
/// a real function, not an assertion, so release builds keep the guard.
void assertSourceDiagnosisSummaryIsPrivate(String text) {
  for (final pattern in _forbiddenSummaryPatterns) {
    if (pattern.hasMatch(text)) {
      throw StateError(
        'Diagnosis summary contains data outside the A5-01 whitelist',
      );
    }
  }
}

final _forbiddenSummaryPatterns = <RegExp>[
  RegExp(r'https?://', caseSensitive: false),
  RegExp(r'\b(?:[A-Za-z_][A-Za-z0-9_]*(?:Exception|Error)|Exception|Error)\b'),
  RegExp(
    r'\b(?:proxy-authorization|authorization|set-cookie|cookies?)\s*[:=]',
    caseSensitive: false,
  ),
  RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(
    r'\b(?:password|passwd|secret|token|api[-_]?key|session[-_]?id)\s*[:=]',
    caseSensitive: false,
  ),
  RegExp(r'\b(?:stack trace|traceback)\b', caseSensitive: false),
];

final _urlPattern = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);

final _exceptionNamePattern = RegExp(
  r'\b(?:[A-Za-z_][A-Za-z0-9_]*(?:Exception|Error)|Exception|Error)\b',
);

final _diagnosedAtFormat = DateFormat('yyyy-MM-dd HH:mm');

String _maskUrls(String text) => text.replaceAll(_urlPattern, '***');

/// Masks URLs and exception class names inside free-form sample titles.
String _sanitizeSampleText(String text) =>
    _maskUrls(text).replaceAll(_exceptionNamePattern, '***');

String _formatDiagnosedAt(DateTime time) =>
    _diagnosedAtFormat.format(time.toLocal());

String _stageSummaryLine(SourceDiagnosisStageResult row) {
  final parts = <String>[
    _stageLabel(row.stage),
    _statusLabel(row.status),
    if (row.kind != null) _kindLabel(row.kind!),
    '${row.elapsedMs} ms',
  ];
  return '- ${parts.join(' · ')}';
}

String _stageLabel(SourceDiagnosisStage stage) {
  return switch (stage) {
    SourceDiagnosisStage.catalog => 'Catalog'.tl,
    SourceDiagnosisStage.details => 'Details'.tl,
    SourceDiagnosisStage.pages => 'Chapter pages'.tl,
    SourceDiagnosisStage.image => 'Image decode'.tl,
  };
}

String _verdictLabel(SourceDiagnosisVerdict verdict) {
  return switch (verdict) {
    SourceDiagnosisVerdict.readable => 'Readable'.tl,
    SourceDiagnosisVerdict.failed => 'Failed'.tl,
    SourceDiagnosisVerdict.unknown => 'Unknown'.tl,
  };
}

String _statusLabel(SourceDiagnosisStatus status) {
  return switch (status) {
    SourceDiagnosisStatus.pass => 'Passed'.tl,
    SourceDiagnosisStatus.fail => 'Failed'.tl,
    SourceDiagnosisStatus.skipped => 'Skipped'.tl,
    SourceDiagnosisStatus.unknown => 'Unknown'.tl,
  };
}

String _kindLabel(DiagnosisFailureKind kind) {
  return switch (kind) {
    DiagnosisFailureKind.unsupported => 'Unsupported'.tl,
    DiagnosisFailureKind.empty => 'No sample found'.tl,
    DiagnosisFailureKind.auth => 'Login required'.tl,
    DiagnosisFailureKind.network => 'Network error'.tl,
    DiagnosisFailureKind.timeout => 'Timed out'.tl,
    DiagnosisFailureKind.image => 'Image error'.tl,
    DiagnosisFailureKind.script => 'Script error'.tl,
    DiagnosisFailureKind.env => 'Environment unavailable'.tl,
  };
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.row});

  final SourceDiagnosisStageResult row;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      _statusLabel(row.status),
      if (row.kind != null) _kindLabel(row.kind!),
      '${row.elapsedMs} ms',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _statusIcon(row.status),
            size: 18,
            color: _statusColor(context, row.status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_stageLabel(row.stage)),
                Text(details, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _statusIcon(SourceDiagnosisStatus status) {
  return switch (status) {
    SourceDiagnosisStatus.pass => Icons.check_circle_outline,
    SourceDiagnosisStatus.fail => Icons.error_outline,
    SourceDiagnosisStatus.skipped => Icons.skip_next_outlined,
    SourceDiagnosisStatus.unknown => Icons.help_outline,
  };
}

Color _statusColor(BuildContext context, SourceDiagnosisStatus status) {
  final scheme = context.colorScheme;
  return switch (status) {
    SourceDiagnosisStatus.pass => scheme.primary,
    SourceDiagnosisStatus.fail => scheme.error,
    SourceDiagnosisStatus.skipped => scheme.outline,
    SourceDiagnosisStatus.unknown => scheme.outline,
  };
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

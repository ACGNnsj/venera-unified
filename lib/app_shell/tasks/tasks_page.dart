import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/follow_updates/follow_updates_scope.dart';
import 'package:venera_unified/features/local_comics/import_export/pdf_import_tasks.dart';
import 'package:venera_unified/features/local_comics/local.dart';
import 'package:venera_unified/features/sync/data_sync_scope.dart';
import 'package:venera_unified/foundation/translations.dart';

import 'task_entry.dart';
import 'tasks_aggregator.dart';

/// Unified tasks center: read-only aggregation over the observable queues
/// plus cancellation where the queue exposes it. Queue logic itself is
/// untouched; this page only snapshots and forwards.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  TasksAggregator? _aggregator;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aggregator ??= TasksAggregator(
      sources: [
        if (LocalManager.current case final manager?)
          DownloadTaskSource(manager),
        PdfImportTaskSource(PdfImportTasks.instance),
        FollowUpdateTaskSource(FollowUpdatesScope.of(context)),
        DataSyncTaskSource(DataSyncScope.of(context)),
        if (SourceInstallationsScope.ownerOf(context).updates
            case final updates?)
          SourceUpdateTaskSource(
            updates,
            nameOf: (key) => ComicSourceManager.current?.find(key)?.name ?? key,
          ),
      ],
    )..addListener(_refresh);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _aggregator?.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final aggregator = _aggregator;
    if (aggregator == null) return const SizedBox.expand();
    final current = aggregator.current;
    final history = aggregator.history;
    return Scaffold(
      appBar: Appbar(title: Text('Tasks'.tl)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            children: [
              AppTabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: '${'Current'.tl} (${current.length})'),
                  Tab(text: '${'History'.tl} (${history.length})'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _TaskListView(
                      key: const PageStorageKey('current-tasks'),
                      entries: current,
                      emptyText: 'No current tasks'.tl,
                      emptyIcon: Icons.task_alt_rounded,
                    ),
                    _TaskListView(
                      key: const PageStorageKey('history-tasks'),
                      entries: history,
                      emptyText: 'No task history'.tl,
                      emptyIcon: Icons.history_rounded,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskListView extends StatelessWidget {
  const _TaskListView({
    super.key,
    required this.entries,
    required this.emptyText,
    required this.emptyIcon,
  });

  final List<TaskEntry> entries;
  final String emptyText;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              emptyIcon,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(emptyText),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) => _TaskCard(entry: entries[index]),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.entry});

  final TaskEntry entry;

  static IconData _kindIcon(TaskKind kind) => switch (kind) {
    TaskKind.download => Icons.download_outlined,
    TaskKind.pdfImport => Icons.picture_as_pdf_outlined,
    TaskKind.followUpdate => Icons.sync,
    TaskKind.dataSync => Icons.cloud_sync_outlined,
    TaskKind.sourceUpdate => Icons.update_outlined,
  };

  static String _statusText(TaskEntryStatus status) => switch (status) {
    TaskEntryStatus.running => 'Running'.tl,
    TaskEntryStatus.paused => 'Paused'.tl,
    TaskEntryStatus.failed => 'Failed'.tl,
    TaskEntryStatus.finished => 'Finished'.tl,
    TaskEntryStatus.canceled => 'Canceled'.tl,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      _statusText(entry.status),
      if (entry.detail != null && entry.detail!.isNotEmpty) entry.detail!,
    ].join(' · ');
    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_kindIcon(entry.kind)),
              title: Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: entry.cancellable
                  ? TextButton(
                      onPressed: () => entry.cancel!(),
                      child: Text('Cancel'.tl),
                    )
                  : null,
            ),
            if (entry.isRunning)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: LinearProgressIndicator(value: entry.progress),
              ),
          ],
        ),
      ),
    );
  }
}

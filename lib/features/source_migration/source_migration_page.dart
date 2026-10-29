import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

import 'source_migration_tasks.dart';

/// Standalone management page for source migration tasks.
///
/// Simplified relative to VeneraX (which embeds these cards in its unified
/// task center): current tasks with progress/cancel/confirm actions on top,
/// finished tasks below with per-item delete and clear-all.
class SourceMigrationTasksPage extends StatelessWidget {
  const SourceMigrationTasksPage({super.key});

  static void open(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SourceMigrationTasksPage()));
  }

  @override
  Widget build(BuildContext context) {
    final manager = SourceMigrationTaskManager.instance;
    return Scaffold(
      appBar: Appbar(
        title: Text('Source migration tasks'.tl),
        actions: [
          IconButton(
            tooltip: 'Clear history'.tl,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: manager.historyTasks.isEmpty
                ? null
                : manager.clearHistory,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          if (manager.currentTasks.isEmpty && manager.historyTasks.isEmpty) {
            return Center(
              child: Text(
                'No tasks yet'.tl,
                style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (manager.currentTasks.isNotEmpty) ...[
                _SectionHeader(title: 'Current tasks'.tl),
                for (final task in manager.currentTasks)
                  _MigrationTaskCard(task: task, manager: manager),
                const SizedBox(height: 8),
              ],
              if (manager.historyTasks.isNotEmpty) ...[
                _SectionHeader(title: 'History'.tl),
                for (final task in manager.historyTasks)
                  _MigrationTaskCard(task: task, manager: manager),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(title, style: ts.s14.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}

class _MigrationTaskCard extends StatelessWidget {
  const _MigrationTaskCard({required this.task, required this.manager});

  final SourceMigrationTask task;
  final SourceMigrationTaskManager manager;

  @override
  Widget build(BuildContext context) {
    final progressText = task.total == 0
        ? '0%'
        : '${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          task.isRunning ? Icons.sync : Icons.swap_horiz,
          color: task.status == SourceMigrationTaskStatus.failed
              ? context.colorScheme.error
              : context.colorScheme.primary,
        ),
        title: Text(
          '${task.folder} → ${task.targetSourceName}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_statusText(task.status)} · $progressText · ${_formatTime(task.createdAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: task.isActive
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (task.isWaitingConfirmation)
                    TextButton(
                      onPressed: () => manager.confirmAll(task.id),
                      child: Text('Confirm All'.tl),
                    ),
                  TextButton(
                    onPressed: () => manager.cancel(task.id),
                    child: Text('Cancel'.tl),
                  ),
                ],
              )
            : IconButton(
                tooltip: 'Delete'.tl,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => manager.removeTask(task.id),
              ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Total: @total  Checked: @checked  Migrated: @migrated  Failed: @failed'
                    .tlParams({
                      'total': task.total,
                      'checked': task.checked,
                      'migrated': task.migrated,
                      'failed': task.failed,
                    }),
                style: ts.s14,
              ),
            ),
          ),
          _MigrationDetails(task: task, manager: manager),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MigrationDetails extends StatelessWidget {
  const _MigrationDetails({required this.task, required this.manager});

  final SourceMigrationTask task;
  final SourceMigrationTaskManager manager;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Migration Details'.tl,
            style: ts.s14.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '${'Target Source'.tl}: ${task.targetSourceName}',
            style: ts.s14,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < task.details.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.details[i].source.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        task.details[i].target == null
                            ? (task.details[i].error ??
                                  _detailStatusText(task.details[i].status))
                            : '${task.details[i].target!.title} · ${_detailStatusText(task.details[i].status)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s12.withColor(
                          task.details[i].status == 'failed'
                              ? context.colorScheme.error
                              : context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (task.isWaitingConfirmation &&
                    task.details[i].status == 'matched')
                  TextButton(
                    onPressed: () => manager.confirm(task.id, i),
                    child: Text('Migrate'.tl),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

String _statusText(SourceMigrationTaskStatus status) {
  return switch (status) {
    SourceMigrationTaskStatus.running => 'Running'.tl,
    SourceMigrationTaskStatus.waitingConfirmation =>
      'Waiting for confirmation'.tl,
    SourceMigrationTaskStatus.completed => 'Completed'.tl,
    SourceMigrationTaskStatus.canceled => 'Canceled'.tl,
    SourceMigrationTaskStatus.failed => 'Failed'.tl,
  };
}

String _detailStatusText(String status) {
  return switch (status) {
    'pending' => 'Pending'.tl,
    'matched' => 'Matched'.tl,
    'migrated' => 'Migrated'.tl,
    'failed' => 'Failed'.tl,
    _ => status,
  };
}

String _formatTime(DateTime time) {
  final local = time.toLocal().toString();
  return local.length >= 16 ? local.substring(0, 16) : local;
}

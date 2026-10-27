import 'package:flutter/material.dart';
import 'package:venera_unified/features/comic_details/comic_details.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

import 'random_comic_picker.dart';

/// Home-page card that draws one random comic from a chosen library.
class RandomComicEntry extends StatefulWidget {
  const RandomComicEntry({super.key});

  @override
  State<RandomComicEntry> createState() => _RandomComicEntryState();
}

class _RandomComicEntryState extends State<RandomComicEntry> {
  RandomComicSource source = RandomComicSource.favorites;
  RandomComicStatus status = RandomComicStatus.any;

  String _sourceLabel(RandomComicSource value) => switch (value) {
    RandomComicSource.favorites => 'Favorites'.tl,
    RandomComicSource.history => 'History'.tl,
    RandomComicSource.local => 'Local'.tl,
  };

  String _statusLabel(RandomComicStatus value) => switch (value) {
    RandomComicStatus.any => 'Any'.tl,
    RandomComicStatus.notStarted => 'Unread'.tl,
    RandomComicStatus.inProgress => 'In progress'.tl,
    RandomComicStatus.completed => 'Completed'.tl,
  };

  void _draw() {
    final comic = RandomComicPicker.pick(
      randomComicDataSource(source),
      status: status,
      historyOf: RandomComicPicker.liveHistoryOf,
    );
    if (!mounted) return;
    if (comic == null) {
      context.showMessage(message: 'No matching comic'.tl);
      return;
    }
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.shuffle, size: 20),
                const SizedBox(width: 8),
                Text('Random Comic'.tl, style: ts.s18),
              ],
            ),
            const SizedBox(height: 12),
            Text('Source'.tl, style: ts.s14),
            const SizedBox(height: 4),
            SegmentedButton<RandomComicSource>(
              showSelectedIcon: false,
              segments: [
                for (final value in RandomComicSource.values)
                  ButtonSegment(
                    value: value,
                    label: Text(_sourceLabel(value)),
                  ),
              ],
              selected: {source},
              onSelectionChanged: (selected) {
                setState(() => source = selected.single);
              },
            ),
            const SizedBox(height: 8),
            Text('Status'.tl, style: ts.s14),
            const SizedBox(height: 4),
            SegmentedButton<RandomComicStatus>(
              showSelectedIcon: false,
              segments: [
                for (final value in RandomComicStatus.values)
                  ButtonSegment(
                    value: value,
                    label: Text(_statusLabel(value)),
                  ),
              ],
              selected: {status},
              onSelectionChanged: (selected) {
                setState(() => status = selected.single);
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _draw,
                icon: const Icon(Icons.casino_outlined),
                label: Text('Surprise me'.tl),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

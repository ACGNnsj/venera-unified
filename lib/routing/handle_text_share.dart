import 'package:venera_unified/foundation/event_subscription.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:flutter/services.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/features/search/search.dart';

/// A caller-owned stream binding. Awaited navigation checks cannot outlive it.
EventSubscription<Object?> createTextShareSubscription() => EventSubscription(
  events: const EventChannel('venera/text_share').receiveBroadcastStream(),
  handle: (event, isActive) async {
    if (appNavigation.mainNavigatorKey == null) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!isActive()) return;
    if (event is String) {
      appNavigation.rootNavigatorKey.currentContext?.to(
        () => AggregatedSearchPage(keyword: event),
      );
    }
  },
  onError: (error, stack) => Log.error('Text share', error, stack),
);

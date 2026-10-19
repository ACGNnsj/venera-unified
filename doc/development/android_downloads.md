# Android download execution

## Scope

User-started image and archive downloads continue to use the existing Dart/JS
source pipeline and `DownloadQueue`. An interactive application binding mirrors
the active queue into a native `dataSync` foreground service. It does not create
a second Flutter engine, another download queue, an alarm, a boot receiver, or
an automatically restarted worker. Restored queue snapshots remain paused.

This addresses missing foreground execution support; it cannot promise that an
OEM battery policy, VPN, proxy, server, or Android force-stop will preserve a
connection. `FLAG_KEEP_SCREEN_ON` is not used for downloading.

## Lifetime and recovery

- Start a service while the activity is visible, as a consequence of starting a
  download. Advancing the queue in the background reuses the same service.
- Display generic progress without comic titles or URLs. Android 13+ notification
  permission is requested once on the first visible start. Denial does not prevent
  foreground-service execution; the in-app pause action remains available.
- A partial CPU wake lock has a two-minute timeout. A native watchdog renews it
  only while Dart supplies a heartbeat (every 30 seconds). After 90 seconds
  without a heartbeat, the service stops and asks Dart to pause its queue.
- Pause, completion, engine teardown, task removal and system timeout release
  the service/wake lock. Android 15+ `onTimeout(startId, fgsType)` stops the service
  immediately, without waiting for Dart acknowledgement. Dart pauses and flushes
  its checkpoint if still alive. No callback is promised after force-stop.
- Owner IDs and increasing session numbers reject stale starts, updates,
  notification actions and stop callbacks. A late binding close cannot dispose
  a replacement binding's service or method-channel handler.
- Typed connection/time-out failures use delays of 2, 5, 10, 20, 30 and 60 seconds
  (at most seven attempts per failing operation, excluding transport-internal
  protocol fallback). Network/foreground events shorten an existing wait, never
  reset this budget. After exhaustion the task is an error requiring manual start.
  Cancellation, HTTP errors, invalid certificates, unsupported data and file
  errors do not enter this connection-recovery loop. Untyped legacy source errors
  retain only their short, bounded retries.
- Failed streams and archive downloaders are closed before retry; completed image
  checkpoints and the current archive workspace/range sidecar are retained.
  Cancelling a task clears pending retry timers and existing owned cleanup.

UIDT jobs are an option for a future engine-independent transfer implementation.
This service deliberately has the lifetime of the current interactive engine;
it is not presented as a durable JobScheduler/WorkManager implementation.

## Validation

Run the Flutter regression tests with the repository's locked dependencies:

```text
flutter pub get --enforce-lockfile
flutter test test/features/local_comics test/app_runtime/android_downloads_test.dart test/app_runtime/interactive_bindings_test.dart
flutter analyze --fatal-infos --fatal-warnings
```

`test/native/download_session_state_test.kt` is a standalone Kotlin/JVM regression
test. Compile it with `DownloadSessionState.kt` and run its main entry point.
Build the Android app as well; pure Dart/JVM tests cannot verify Android service
promotion, wake locks, notification permission, or OEM process management.

Device acceptance matrix (including the reported MagicOS 10 / Android 16):

1. Start a multi-page download in the foreground, then use Home and screen-off
   for at least five minutes. Check progress, notification and subsequent queue
   entries. Repeat on Wi-Fi and mobile data, with and without a VPN/proxy.
2. Temporarily remove connectivity, then restore it. Check the waiting state,
   finite retries and preserved completed pages. Pause/cancel while waiting;
   reconnect and foreground the app, verifying that it stays paused/cancelled.
3. Pause from the notification. Verify the queue checkpoint, notification removal
   and absence of `VeneraNext:downloads` in `adb shell dumpsys power`.
4. Deny notification permission; verify foreground download is still usable and
   manual in-app pause works. No repeated permission prompt on every retry.
5. Remove the app from recents and reopen it. Check paused recovery. Force-stop
   separately; do not expect a callback or automatic restart.
6. On a disposable Android 15+ test device, shorten the dataSync timeout with
   `adb shell device_config put activity_manager data_sync_fgs_timeout_duration 10000`.
   Start a download, background it, and verify clean pause without an ANR. Restore
   the device setting with `adb shell device_config delete activity_manager data_sync_fgs_timeout_duration`.

Issue reports should include the exact app version/build, device model and OS,
source/version, image versus archive download, network/VPN/proxy setup, time to
failure, whether manual foreground start recovers, and the complete error/log.
Redact credentials, cookies, tokens, signed URLs and personal paths before posting.

References:

- https://developer.android.com/develop/background-work/services/fgs/service-types#data-sync
- https://developer.android.com/develop/background-work/services/fgs/timeout
- https://developer.android.com/develop/background-work/background-tasks/uidt

# App-data synchronization

Open **Settings → App → Data Sync** and enter a WebDAV directory URL, username, and password. Preserve the server directory's letter case. Use **Test Connection** to check directory access.

App data includes settings, favorites, history, cookies, and source files, but excludes local comic images. Comic archive backups and the online WebDAV library are configured separately.

File downloads support redirect links supplied by the WebDAV service, such as 123 Cloud's HTTPS download hosts. Cross-origin downloads do not receive WebDAV credentials or cookies, and HTTPS-to-HTTP downgrades are rejected. Directory listing, upload, and deletion remain restricted to the configured WebDAV endpoint; if those requests redirect, use the final WebDAV directory URL supplied by the service.

## Modes

| Mode | Behavior |
|---|---|
| Manual | Transfer only when you use the Home sync card's Upload or Download buttons |
| Real-time | Upload local changes; check for remote updates at startup and on resume, with at least 10 minutes between resume checks |
| Scheduled | Sync every 5, 15, 30, 60, 180, or 360 minutes; defaults to 30 minutes |

Scheduled sync batches local edits into one upload. With no pending edits, it checks the remote version and downloads only when a newer snapshot exists. Changes made during an upload remain pending until the next interval. Failed attempts retain pending changes and retry after another interval.

The timer runs only while the app process is running and never wakes the system after the app closes. Pending changes and the last attempt time persist on the device. Startup and resume catch up overdue syncs; otherwise, the app waits for the remaining interval. Mobile operating systems may suspend background work, so exact timing is not guaranteed.

The Home Upload and Download buttons work immediately in all three modes and restart the interval when the operation finishes. An explicit download applies the remote snapshot using the existing import rules. If local edits have not been uploaded, decide which device's data to keep first; synchronization does not merge concurrent edits across devices.

## Saving settings

For real-time or scheduled mode, choose an initial upload or download and select **Continue**. Settings are saved after that operation succeeds. Failure restores the previous endpoint, mode, interval, and excluded fields. In manual mode, Continue only saves settings.

Changing the mode or interval reschedules the next check. Clear the URL, username, and password and save to disconnect. Existing automatic-sync preferences map to real-time when enabled and manual when disabled; upgrading does not enable scheduled sync automatically.

Excluded settings affect only the named fields. The sync mode, interval, and WebDAV connection settings are already device-local and cannot be overwritten by another device.

## First sync after upgrading

If automatic sync reports `Complete an upload or download a newer backup to resume automatic sync.`, this device has no verified synchronized-content baseline; it does not necessarily indicate a connection failure. After upgrading or changing the endpoint or excluded fields, choose which device's data to keep and complete a manual sync. Upload to keep local data, or download and confirm replacement of local edits to use the remote backup. A download that only checks for updates without importing data does not establish a baseline.

Once an upload or import succeeds, automatic sync can compare local changes again. If it fails, do not clear app data or delete recovery records; export a local backup first and resolve the specific transfer error.

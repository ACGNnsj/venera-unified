import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

import 'webdav_qr_payload.dart';

/// Shows the current WebDAV sync configuration as a scannable QR code.
///
/// Available on all platforms. The code embeds the password in cleartext,
/// so the dialog warns before displaying it.
void showWebdavSyncQrDialog(
  BuildContext context,
  WebdavSyncQrPayload payload,
) {
  final data = payload.toQrData();
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: 'WebDAV config QR code'.tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scan this QR code on another device to import the WebDAV configuration.'
                  .tl,
            ).paddingHorizontal(16),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                size: 280,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ).toCenter(),
            const SizedBox(height: 12),
            Text(
              'The QR code contains your WebDAV password. Only show it to trusted devices.'
                  .tl,
              style: ts.s14,
            ).paddingHorizontal(16),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: data));
              context.showMessage(message: 'Copied to clipboard'.tl);
            },
            child: Text('Copy'.tl),
          ),
          TextButton(
            onPressed: () => context.pop(),
            child: Text('Close'.tl),
          ),
        ],
      );
    },
  );
}

/// Full-screen camera page that imports a WebDAV config from a QR code.
///
/// Only reachable on Android/iOS; callers must hide the entry on desktop
/// instead of navigating here. Pops with the parsed [WebdavSyncQrPayload],
/// or null when the user backs out.
class WebdavSyncQrScannerPage extends StatefulWidget {
  const WebdavSyncQrScannerPage({super.key});

  @override
  State<WebdavSyncQrScannerPage> createState() =>
      _WebdavSyncQrScannerPageState();
}

class _WebdavSyncQrScannerPageState extends State<WebdavSyncQrScannerPage> {
  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool handled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void handleDetect(BarcodeCapture capture) {
    if (handled) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final data = barcode.rawValue;
      if (data == null) {
        continue;
      }
      final config = WebdavSyncQrPayload.tryParse(data);
      if (config == null || !config.isValid) {
        context.showMessage(message: 'Invalid WebDAV config QR code.'.tl);
        continue;
      }
      handled = true;
      controller.stop();
      context.pop(config);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Scan WebDAV config QR code'.tl)),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: handleDetect,
            onDetectError: (error, stackTrace) {
              context.showMessage(message: error.toString());
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              color: Colors.black.withValues(alpha: 0.6),
              child: Text(
                'Point the camera at a Venera WebDAV config QR code.'.tl,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

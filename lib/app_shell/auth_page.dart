import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_unified/app_shell/pin_pad.dart';
import 'package:venera_unified/foundation/auth_storage.dart';
import 'package:venera_unified/foundation/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  /// 需要 PIN 输入盘（生物识别不可用、被取消，或校验失败且用户设置过 PIN）。
  bool _askPin = false;

  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (SchedulerBinding.instance.lifecycleState !=
          AppLifecycleState.paused) {
        auth();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: Center(
          child: _askPin
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.pin, size: 36),
                    const SizedBox(height: 16),
                    Text('Enter PIN'.tl),
                    const SizedBox(height: 24),
                    PinPad(error: _error, onSubmitted: _verifyPin),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.security, size: 36),
                    const SizedBox(height: 16),
                    Text('Authentication Required'.tl),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(onPressed: auth, child: Text('Continue'.tl)),
                  ],
                ),
        ),
      ),
    );
  }

  void _unlock() => widget.onSuccessfulAuth?.call();

  Future<void> _verifyPin(String pin) async {
    final ok = await AuthStorage.verify(pin);
    if (!mounted) return;
    if (ok) {
      _unlock();
    } else {
      setState(() => _error = 'PIN does not match'.tl);
    }
  }

  /// 有生物识别就走系统弹窗；没有（或用户取消）且设置过 PIN 时退回 PIN 输入。
  ///
  /// 没有生物识别、也没有设置 PIN 时保持旧行为直接放行——此时用户没有任何可用的
  /// 凭据，拦下来只会把人锁在门外。
  Future<void> auth() async {
    final localAuth = LocalAuthentication();
    var supported = false;
    try {
      supported =
          await localAuth.canCheckBiometrics ||
          await localAuth.isDeviceSupported();
    } catch (_) {
      supported = false;
    }
    if (supported) {
      var isAuthorized = false;
      try {
        isAuthorized = await localAuth.authenticate(
          localizedReason: 'Please authenticate to continue'.tl,
        );
      } catch (_) {
        isAuthorized = false;
      }
      if (isAuthorized) {
        _unlock();
        return;
      }
    }
    final hasPin = await AuthStorage.hasPassword();
    if (!mounted) return;
    if (hasPin) {
      setState(() {
        _askPin = true;
        _error = null;
      });
      return;
    }
    if (!supported) {
      _unlock();
    } else {
      setState(() => _error = 'Authentication failed'.tl);
    }
  }
}

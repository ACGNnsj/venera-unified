import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_unified/components/pattern_lock.dart';
import 'package:venera_unified/components/pin_pad.dart';
import 'package:venera_unified/foundation/auth_storage.dart';
import 'package:venera_unified/foundation/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  /// 生物识别走不通时退回的凭据输入（按已存凭据类型分支）；null 表示还没到那步。
  AppLockType? _fallback;

  String? _error;

  final _passwordController = TextEditingController();
  bool _patternError = false;

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
          child: _fallback == null ? _buildBiometric() : _buildFallback(),
        ),
      ),
    );
  }

  Widget _buildBiometric() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.security, size: 36),
        const SizedBox(height: 16),
        Text('Authentication Required'.tl),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(onPressed: auth, child: Text('Continue'.tl)),
      ],
    );
  }

  Widget _buildFallback() {
    return switch (_fallback) {
      AppLockType.password => _buildPasswordEntry(),
      AppLockType.pattern => _buildPatternEntry(),
      _ => _buildPinEntry(),
    };
  }

  Widget _buildPinEntry() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.pin, size: 36),
        const SizedBox(height: 16),
        Text('Enter PIN'.tl),
        const SizedBox(height: 24),
        PinPad(error: _error, onSubmitted: _verifyPin),
      ],
    );
  }

  Widget _buildPasswordEntry() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 36),
          const SizedBox(height: 16),
          Text('Enter Password'.tl, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TextField(
              controller: _passwordController,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _verifyPassword(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _verifyPassword, child: Text('Unlock'.tl)),
        ],
      ),
    );
  }

  Widget _buildPatternEntry() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.pattern, size: 36),
        const SizedBox(height: 16),
        Text(
          _patternError ? 'Incorrect'.tl : 'Draw pattern to unlock'.tl,
          style: TextStyle(
            fontSize: 16,
            color: _patternError ? Theme.of(context).colorScheme.error : null,
          ),
        ),
        const SizedBox(height: 24),
        PatternLock(
          dimByDefault: _patternError,
          onComplete: (pattern) async {
            if (await AuthStorage.verify(patternToString(pattern))) {
              _unlock();
            } else if (mounted) {
              setState(() => _patternError = true);
            }
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
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

  Future<void> _verifyPassword() async {
    final ok = await AuthStorage.verify(_passwordController.text);
    if (!mounted) return;
    if (ok) {
      _unlock();
    } else {
      setState(() => _error = 'Incorrect'.tl);
    }
  }

  /// 有生物识别就走系统弹窗；没有（或用户取消）且设置过凭据时退回凭据输入
  /// （按已存类型分支：PIN 输入盘 / 密码框 / 图案锁）。
  ///
  /// 没有生物识别、也没有设置凭据时保持旧行为直接放行——此时用户没有任何可用的
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
    final type = await AuthStorage.credentialType();
    if (!mounted) return;
    if (type != null) {
      setState(() {
        _fallback = type;
        _error = null;
        _patternError = false;
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

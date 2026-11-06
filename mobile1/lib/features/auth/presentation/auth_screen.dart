import 'package:flutter/material.dart';

import '../../../core/di/service_locator.dart';
import '../../../core/state/app_state.dart';
import '../domain/auth_repository.dart';

/// Email/password sign in and Google OAuth (matches mobile1 auth.tsx).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Mode { signin, signup }

enum _ResetStep { hidden, email, otp, password }

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _otpController = TextEditingController();
  final _resetEmailController = TextEditingController();
  final _resetOtpController = TextEditingController();
  final _newPasswordController = TextEditingController();

  AuthRepository get _auth => sl<AuthRepository>();

  bool _busy = false;
  String _error = '';
  String _notice = '';
  _Mode _mode = _Mode.signin;
  String? _pendingEmail;
  bool _showOtp = false;
  _ResetStep _resetStep = _ResetStep.hidden;

  @override
  void initState() {
    super.initState();
    // Rebuild so the submit button enables/disables as the user types.
    _emailController.addListener(_onFieldChanged);
    _passwordController.addListener(_onFieldChanged);
    _nameController.addListener(_onFieldChanged);
    _otpController.addListener(_onFieldChanged);
    _resetEmailController.addListener(_onFieldChanged);
    _resetOtpController.addListener(_onFieldChanged);
    _newPasswordController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    setState(() {});
  }

  /// Closes the fullscreen auth dialog once a session exists. MainTabs
  /// listens to AppState and has already rebuilt behind this route, but the
  /// modal stays stacked on top until it is popped — without this the user
  /// appears "stuck" on the sign-in page and only phone-back dismisses it.
  void _closeAfterAuth() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _emailController.removeListener(_onFieldChanged);
    _passwordController.removeListener(_onFieldChanged);
    _nameController.removeListener(_onFieldChanged);
    _otpController.removeListener(_onFieldChanged);
    _resetEmailController.removeListener(_onFieldChanged);
    _resetOtpController.removeListener(_onFieldChanged);
    _newPasswordController.removeListener(_onFieldChanged);
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _otpController.dispose();
    _resetEmailController.dispose();
    _resetOtpController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submitEmail() async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });

    final isRegister = _mode == _Mode.signup;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (isRegister && password.length < 6) {
      setState(() {
        _busy = false;
        _error = AppState.instance.t('auth.passwordMinLength');
      });
      return;
    }

    if (isRegister) {
      final res = await _auth.signUpWithEmail(email, password, fullName: _nameController.text.trim());
      if (!mounted) return;
      if (!res.ok) {
        setState(() {
          _busy = false;
          _error = res.error ?? 'Sign-up failed';
        });
      } else if (res.needsConfirmation) {
        setState(() {
          _busy = false;
          _pendingEmail = email;
          _showOtp = true;
        });
      } else {
        setState(() {
          _busy = false;
        });
        // Auto-session (email confirmation off): leave the auth screen.
        _closeAfterAuth();
      }
    } else {
      final res = await _auth.signInWithEmail(email, password);
      if (!mounted) return;
      if (!res.ok) {
        setState(() {
          _busy = false;
          _error = res.error ?? 'Sign-in failed';
        });
      } else {
        setState(() {
          _busy = false;
        });
        _closeAfterAuth();
      }
    }
  }

  Future<void> _verifyOtp() async {
    if (_pendingEmail == null) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.verifyEmailOtp(_pendingEmail!, _otpController.text.trim());
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error ?? 'Verification failed';
      });
    } else {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _resendConfirmation() async {
    if (_pendingEmail == null) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.resendConfirmation(_pendingEmail!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!res.ok) {
        _error = res.error ?? 'Resend failed';
      } else {
        _notice = AppState.instance.t('auth.confirmationResent');
      }
    });
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.signInWithGoogle();
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error == 'cancelled' ? '' : (res.error ?? 'Sign-in failed');
      });
    } else {
      setState(() {
        _busy = false;
      });
      _closeAfterAuth();
    }
  }

  Future<void> _requestReset() async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final email = _resetEmailController.text.trim();
    final res = await _auth.requestPasswordReset(email);
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error ?? 'Reset request failed';
      });
    } else {
      setState(() {
        _busy = false;
        _notice = AppState.instance.t('auth.resetSent');
        _resetStep = _ResetStep.otp;
      });
    }
  }

  Future<void> _verifyResetOtp() async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.verifyPasswordResetOtp(
      _resetEmailController.text.trim(),
      _resetOtpController.text.trim(),
    );
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error ?? 'Verification failed';
      });
    } else {
      setState(() {
        _busy = false;
        _notice = '';
        _resetStep = _ResetStep.password;
      });
    }
  }

  Future<void> _resendReset() async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.requestPasswordReset(_resetEmailController.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!res.ok) {
        _error = res.error ?? 'Resend failed';
      } else {
        _notice = AppState.instance.t('auth.resetSent');
      }
    });
  }

  Future<void> _saveNewPassword() async {
    final password = _newPasswordController.text;
    if (password.length < 6) {
      setState(() {
        _error = AppState.instance.t('auth.passwordMinLength');
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    final res = await _auth.updatePassword(password);
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error ?? 'Update failed';
      });
    } else {
      setState(() {
        _busy = false;
        _notice = AppState.instance.t('auth.resetDone');
      });
      // Close the reset flow and return to the app (session established).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  void _closeReset() {
    setState(() {
      _resetStep = _ResetStep.hidden;
      _resetEmailController.clear();
      _resetOtpController.clear();
      _newPasswordController.clear();
      _error = '';
      _notice = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Icon(Icons.chair, size: 36, color: theme.colorScheme.primary),
                    ),
                  ),
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Georgia',
                      ),
                      children: [
                        const TextSpan(text: 'Addis'),
                        TextSpan(
                          text: 'Home',
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.t('auth.welcome'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 32),

                  OutlinedButton.icon(
                    onPressed: _busy ? null : _google,
                    icon: const Icon(Icons.g_mobiledata, size: 24),
                    label: Text(state.t('auth.google')),
                  ),

                  const SizedBox(height: 24),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('OR', style: theme.textTheme.labelMedium),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 16),

                  if (_resetStep != _ResetStep.hidden)
                    _buildResetCard(theme, state)
                  else if (_showOtp)
                    _buildConfirmationCard(theme, state)
                  else ...[
                    SegmentedButton<_Mode>(
                      segments: [
                        ButtonSegment(value: _Mode.signin, label: Text(state.t('auth.signIn'))),
                        ButtonSegment(value: _Mode.signup, label: Text(state.t('auth.createAccount'))),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) => setState(() {
                        _mode = s.first;
                        _error = '';
                        _notice = '';
                      }),
                    ),
                    const SizedBox(height: 20),
                    _buildEmailForm(theme, state),
                  ],

                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                    ),
                  ],
                  if (_notice.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _notice,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.primary, fontSize: 13),
                    ),
                  ],

                  const SizedBox(height: 48),
                  Text(
                    state.t('auth.madeInEthiopia'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmationCard(ThemeData theme, AppState state) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.mail_outline, size: 24, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            state.t('auth.checkEmail'),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            state.t('auth.checkEmailHint'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(letterSpacing: 4, fontSize: 24, fontWeight: FontWeight.bold),
            decoration: const InputDecoration(
              hintText: '123456',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _otpController.text.trim().length < 6 ? null : _verifyOtp,
            child: const Text('Verify Code'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : _resendConfirmation,
            child: Text(state.t('auth.resendConfirmation')),
          ),
        ],
      ),
    );
  }

  Widget _buildResetCard(ThemeData theme, AppState state) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.key_outlined, size: 22, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            state.t('auth.resetTitle'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (_resetStep == _ResetStep.email) ...[
            Text(
              state.t('auth.resetHint'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _resetEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: state.t('auth.email')),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _resetEmailController.text.trim().isEmpty ? null : _requestReset,
              child: Text(state.t('auth.resetSend')),
            ),
          ] else if (_resetStep == _ResetStep.otp) ...[
            Text(
              '${state.t('auth.resetSentTo')} ${_resetEmailController.text.trim()}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _resetOtpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(letterSpacing: 4, fontSize: 24, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(hintText: '123456', counterText: ''),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _resetOtpController.text.trim().length < 6 ? null : _verifyResetOtp,
              child: Text(state.t('auth.resetVerify')),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : _resendReset,
              child: Text(state.t('auth.resetResend')),
            ),
          ] else ...[
            TextField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: InputDecoration(labelText: state.t('auth.resetNewPassword')),
            ),
            const SizedBox(height: 4),
            Text(
              state.t('auth.passwordMinLength'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _newPasswordController.text.length < 6 ? null : _saveNewPassword,
              child: Text(state.t('auth.resetSave')),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : _closeReset,
            child: Text(state.t('auth.backToSignIn')),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailForm(ThemeData theme, AppState state) {
    final isRegister = _mode == _Mode.signup;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isRegister) ...[
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: state.t('auth.fullName')),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: state.t('auth.email')),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: InputDecoration(labelText: state.t('auth.password')),
        ),
        if (isRegister) ...[
          const SizedBox(height: 4),
          Text(
            state.t('auth.passwordMinLength'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
        if (!isRegister) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _resetStep = _ResetStep.email;
                        _error = '';
                        _notice = '';
                      }),
              child: Text(
                state.t('auth.forgotPassword'),
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || _emailController.text.trim().isEmpty || _passwordController.text.isEmpty
              ? null
              : _submitEmail,
          child: Text(isRegister ? state.t('auth.createAccount') : state.t('auth.signIn')),
        ),
      ],
    );
  }
}

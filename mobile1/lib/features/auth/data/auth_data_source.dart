import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/env.dart';
import '../../../core/network/supabase_api.dart';
import '../../../core/network/supabase_client.dart';

/// Auth helpers. Phone OTP uses the `otp-auth` edge function (service-role
/// flow mirroring the web app's server functions); email/password and Google
/// use native Supabase auth.
class AuthDataSource {
  AuthDataSource._();

  /// Normalises an auth error into a short, UI-safe message.
  static String errorOf(Object e) {
    if (e is AuthException) {
      return e.message.toLowerCase().contains('invalid') ? 'invalid_credentials' : e.message;
    }
    return '$e';
  }

  static String? get currentUserId => AppSupabase.client.auth.currentUser?.id;

  // ── Email / password ──────────────────────────────────────────────────

  static Future<AuthResponse> signInWithEmail(String email, String password) {
    return AppSupabase.client.auth.signInWithPassword(email: email, password: password);
  }

  static Future<AuthResponse> signUpWithEmail(String email, String password, {String? fullName}) {
    return AppSupabase.client.auth.signUp(
      email: email,
      password: password,
      data: fullName != null && fullName.trim().isNotEmpty ? {'full_name': fullName.trim()} : null,
    );
  }

  static Future<AuthResponse> verifyEmailOtp(String email, String token) {
    return AppSupabase.client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.signup,
    );
  }

  static Future<void> resendConfirmation(String email) {
    return AppSupabase.client.auth.resend(
      type: OtpType.signup,
      email: email,
    );
  }

  static Future<void> requestPasswordReset(String email) {
    return AppSupabase.client.auth.resetPasswordForEmail(email);
  }

  static Future<AuthResponse> verifyResetOtp(String email, String token) {
    return AppSupabase.client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.recovery,
    );
  }

  static Future<void> updatePassword(String newPassword) {
    return AppSupabase.client.auth.updateUser(UserAttributes(password: newPassword));
  }

  // ── Google Sign-In (native credential flow — no browser) ───────────────
  // google_sign_in does the app-native account flow (no browser redirect, no
  // addisfurnish:// deep link). The Android OAuth client in Google Cloud is
  // matched through the app's package name + SHA-1 fingerprint; passing the
  // Web client id as serverClientId makes the result carry an idToken whose
  // audience Supabase accepts. signInWithIdToken then creates the session
  // directly — Google's webhook-free, browser-free path.
  static Future<void> signInWithGoogle() async {
    debugPrint('[Auth] native Google sign-in started');
    final GoogleSignIn google = GoogleSignIn(
      serverClientId: Env.googleWebClientId.isNotEmpty
          ? Env.googleWebClientId
          : null,
      scopes: const <String>['email', 'profile'],
    );
    try {
      final GoogleSignInAccount? account;
      try {
        account = await google.signIn();
      } on PlatformException catch (e) {
        debugPrint('[Auth] Google platform error: code=${e.code} '
            'message=${e.message} details=${e.details}');
        // DEVELOPER_ERROR surfaces as code 10 (and in Play-services logs as
        // "cd.d:10"): the installed app's package name + signing SHA-1 are not
        // registered on any Android OAuth client in the Google Cloud project
        // that owns [serverClientId]. Nothing the user can fix in-app —
        // surface development guidance instead of a dead "sign_in_failed".
        if (e.code == '10' || e.code == 'sign_in_failed' ||
            e.code == 'DEVELOPER_ERROR') {
          throw 'Google sign-in is not configured for this build.\n'
              'Register the Android OAuth client in Google Cloud with '
              'package com.addisfurnish.addisfurnish and signing SHA-1 '
              '19:AB:54:80:A7:F4:98:F1:58:B1:DC:EB:EB:79:BA:FD:C7:06:D3:36, '
              'then rebuild.';
        }
        // Everything else (network, api-not-available) keeps its own message.
        throw 'Google sign-in failed (${e.code}): ${e.message ?? 'unknown'}';
      }
      if (account == null) {
        debugPrint('[Auth] Google sign-in cancelled by user');
        throw 'cancelled';
      }
      final googleAuth = await account.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw 'Google sign-in failed: no id token (check the Web client id '
            'define and the app SHA-1 registered in Google Cloud)';
      }
      await AppSupabase.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
      debugPrint('[Auth] Google id token exchanged, session established');
    } finally {
      // Release the granted scopes; keeps the account picker fresh next time.
      try {
        await google.disconnect();
      } catch (_) {}
    }
  }

  // ── Session / profile ─────────────────────────────────────────────────

  static Future<void> refreshProfile(String userId) =>
      SupabaseApi.fetchProfile(userId).then((_) {});

  static Future<void> signOut() => AppSupabase.client.auth.signOut();
}

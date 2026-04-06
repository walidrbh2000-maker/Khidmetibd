// lib/models/login_state.dart

import 'package:equatable/equatable.dart';

// ============================================================================
// LOGIN STATUS
// ============================================================================

enum LoginStatus { initial, loading, success, error }

// ============================================================================
// LOGIN STATE
// ============================================================================

class LoginState extends Equatable {
  /// Current status of the login process
  final LoginStatus status;

  /// Error message to display — holds a localization key, not raw text.
  /// Resolved via context.tr(state.errorMessage!) in the screen.
  final String? errorMessage;

  /// Email being entered (used to pre-fill the forgot-password sheet)
  final String? email;

  // FIX [DEAD CODE REMOVED]:
  // `isPasswordVisible` and its companion `togglePasswordVisibility()` in
  // LoginController were never consumed by the screen — GlassPasswordField
  // manages its own visibility state internally. Keeping this field caused
  // unnecessary state rebuilds on every toggle tap. Removed entirely.

  const LoginState({
    this.status = LoginStatus.initial,
    this.errorMessage,
    this.email,
  });

  /// Convenience getters for UI logic
  bool get isLoading => status == LoginStatus.loading;
  bool get hasError => status == LoginStatus.error;
  bool get isSuccess => status == LoginStatus.success;
  bool get isInitial => status == LoginStatus.initial;

  /// Creates a copy with updated fields
  LoginState copyWith({
    LoginStatus? status,
    String? errorMessage,
    String? email,
    bool clearError = false,
  }) {
    return LoginState(
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      email: email ?? this.email,
    );
  }

  @override
  List<Object?> get props => [status, errorMessage, email];

  @override
  String toString() =>
      'LoginState(status: $status, hasError: $hasError, email: $email)';
}

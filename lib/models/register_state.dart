// lib/models/register_state.dart

import 'package:equatable/equatable.dart';

// ============================================================================
// REGISTER STATUS
// ============================================================================

enum RegisterStatus { initial, loading, success, error }

// ============================================================================
// REGISTER STATE
// ============================================================================

class RegisterState extends Equatable {
  /// Current status of the registration process
  final RegisterStatus status;

  /// Error message — holds a localization key, not raw text.
  /// Resolved via context.tr(state.errorMessage!) in the screen.
  final String? errorMessage;

  // FIX [DEAD CODE REMOVED]:
  // `isPasswordVisible` and `isConfirmPasswordVisible` were never consumed by
  // RegisterScreen — GlassPasswordField self-manages its own obscure/reveal
  // state internally. Their companion methods togglePasswordVisibility() and
  // toggleConfirmPasswordVisibility() in RegisterController were also dead.
  // Removing all 4 items eliminates unnecessary state rebuilds.

  /// Whether the user is registering as a worker
  final bool isWorker;

  /// Selected service type (for workers only)
  final String? selectedService;

  /// Whether the user has accepted terms and conditions
  final bool termsAccepted;

  /// Full name being entered (for potential auto-fill scenarios)
  final String? fullName;

  /// Email being entered (for potential auto-fill scenarios)
  final String? email;

  /// Phone number being entered (for potential auto-fill scenarios)
  final String? phoneNumber;

  const RegisterState({
    this.status = RegisterStatus.initial,
    this.errorMessage,
    this.isWorker = false,
    this.selectedService,
    this.termsAccepted = false,
    this.fullName,
    this.email,
    this.phoneNumber,
  });

  /// Convenience getters for UI logic
  bool get isLoading => status == RegisterStatus.loading;
  bool get hasError => status == RegisterStatus.error;
  bool get isSuccess => status == RegisterStatus.success;
  bool get isInitial => status == RegisterStatus.initial;

  /// Creates a copy with updated fields
  RegisterState copyWith({
    RegisterStatus? status,
    String? errorMessage,
    bool? isWorker,
    String? selectedService,
    bool? termsAccepted,
    String? fullName,
    String? email,
    String? phoneNumber,
    bool clearError = false,
    bool clearService = false,
  }) {
    return RegisterState(
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isWorker: isWorker ?? this.isWorker,
      selectedService:
          clearService ? null : (selectedService ?? this.selectedService),
      termsAccepted: termsAccepted ?? this.termsAccepted,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
    );
  }

  @override
  List<Object?> get props => [
        status,
        errorMessage,
        isWorker,
        selectedService,
        termsAccepted,
        fullName,
        email,
        phoneNumber,
      ];

  @override
  String toString() =>
      'RegisterState(status: $status, hasError: $hasError, '
      'isWorker: $isWorker, termsAccepted: $termsAccepted)';
}

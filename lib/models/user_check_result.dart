// lib/models/user_check_result.dart
//
// Data contract for GET /auth/check?uid=:uid (AuthController NestJS).
//
// Response shape (from auth.service.ts → UserCheckResult):
//   { isNewUser: boolean, role: string | null }
//
// isNewUser == true  → no MongoDB profile → redirect to /role-selection
// isNewUser == false → profile exists     → redirect to /home

class UserCheckResult {
  /// True when no MongoDB profile exists for the Firebase UID.
  /// Safe default on error: treat as new user (setup screen upserts safely).
  final bool isNewUser;

  /// 'client' | 'worker' when isNewUser == false, null otherwise.
  final String? role;

  const UserCheckResult({
    required this.isNewUser,
    this.role,
  });

  factory UserCheckResult.fromJson(Map<String, dynamic> json) {
    return UserCheckResult(
      isNewUser: json['isNewUser'] as bool? ?? true,
      role:      json['role']      as String?,
    );
  }

  /// Safe default: treat unknown state as new user.
  static const UserCheckResult newUser =
      UserCheckResult(isNewUser: true, role: null);

  @override
  String toString() =>
      'UserCheckResult(isNewUser: $isNewUser, role: $role)';
}

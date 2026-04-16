// lib/router/app_router.dart
//
// MIGRATION NOTE:
//   - /login, /register, /forgot-password, /verify-email removed.
//   + /onboarding, /phone-auth, /role-selection, /user-profile-setup,
//     /worker-profile-setup added.
//   - Email verification check removed from redirect.
//   + Onboarding check added: new installs see /onboarding before /phone-auth.
//   - loginControllerProvider / registerControllerProvider removed.
//   - AuthController (phone) is screen-scoped (autoDispose) — not in router.
//
// Redirect logic summary:
//   1. App not initialized → /splash
//   2. Onboarding not done → /onboarding
//   3. Not logged in → /phone-auth  (save deep link for post-auth restore)
//   4. Logged in + role unknown → wait (null redirect)
//   5. Role guard: /worker/* paths blocked for clients
//   6. /worker-home → /home
//
// NAMING NOTE:
//   Two files share a similar purpose but are distinct widgets:
//
//   lib/screens/auth/worker_profile_screen.dart
//     → WorkerProfileSetupScreen  (new-user setup flow, no params)
//
//   lib/screens/worker_profile/worker_profile_screen.dart
//     → WorkerProfileScreen  (public profile viewer, requires workerId)
//
//   The auth setup screen was renamed WorkerProfileSetupScreen to eliminate
//   the compile-time ambiguity when both are imported in this file.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/splash/splash_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/auth/phone_auth_screen.dart';
import '../screens/auth/role_selection_screen.dart';
import '../screens/auth/user_profile_screen.dart';
// WorkerProfileSetupScreen — new-user worker setup (renamed to avoid collision)
import '../screens/auth/worker_profile_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/main_navigation_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/service_request/service_request_screen.dart';
import '../screens/service_request/bids_list_screen.dart';
import '../screens/service_request/request_tracking_screen.dart';
import '../screens/service_request/rating_screen.dart';
import '../screens/worker_jobs/worker_jobs_screen.dart';
import '../screens/worker_jobs/job_detail_screen.dart';
import '../screens/worker_jobs/submit_bid_screen.dart';
import '../screens/edit_profile/edit_profile_screen.dart';
// WorkerProfileScreen — public profile viewer (requires workerId param)
import '../screens/worker_profile/worker_profile_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/about/about_screen.dart';
import '../screens/help/help_screen.dart';
import '../providers/auth_providers.dart';
import '../providers/core_providers.dart';
import '../providers/onboarding_controller.dart';
import '../providers/user_role_provider.dart';
import '../services/auth_service.dart';
import '../utils/composite_listenable.dart';
import '../utils/constants.dart';
import '../utils/localization.dart';
import '../utils/logger.dart';

// ── Deep-link restoration ──────────────────────────────────────────────────
//
// When a guest hits a protected route, we store the target path here.
// After successful auth, the router restores the original destination
// instead of always landing on /home.
//
// Auth-specific paths are never stored (would cause post-login loops).

final pendingDeepLinkProvider = StateProvider<String?>((ref) => null);

// ── Router provider ────────────────────────────────────────────────────────

final goRouterProvider = Provider<GoRouter>((ref) {
  final authService      = ref.read(authServiceProvider);
  final redirectNotifier = ref.read(authRedirectNotifierProvider);

  final userIdentityListenable = _UserIdentityListenable(authService);
  final listenable = CompositeListenable([
    userIdentityListenable,
    redirectNotifier,
  ]);

  ref.onDispose(() {
    userIdentityListenable.dispose();
    listenable.dispose();
  });

  // Matches /worker/<single segment> (worker profile view — accessible to all).
  final _workerProfilePattern = RegExp(r'^/worker/[^/]+$');

  // Auth paths — never stored as pending deep links.
  const _authPaths = {
    AppRoutes.splash,
    AppRoutes.onboarding,
    AppRoutes.phoneAuth,
    AppRoutes.roleSelection,
    AppRoutes.userProfileSetup,
    AppRoutes.workerProfileSetup,
  };

  return GoRouter(
    initialLocation: AppRoutes.splash,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: listenable,

    redirect: (context, state) {
      final appInitialized = ref.read(appInitializedProvider);
      if (!appInitialized) {
        return state.matchedLocation == AppRoutes.splash ? null : AppRoutes.splash;
      }

      final isLoggedIn  = authService.isLoggedIn;
      final currentPath = state.matchedLocation;

      final isOnSplash       = currentPath == AppRoutes.splash;
      final isOnOnboarding   = currentPath == AppRoutes.onboarding;
      final isOnAuth         = currentPath == AppRoutes.phoneAuth;
      final isOnSetup        = currentPath == AppRoutes.roleSelection
                            || currentPath == AppRoutes.userProfileSetup
                            || currentPath == AppRoutes.workerProfileSetup;
      final isOnWorkerHome   = currentPath == AppRoutes.workerHome;
      final isOnWorkerRoute  = currentPath.startsWith('/worker');

      final cachedRole      = ref.read(cachedUserRoleProvider);
      final onboardingDone  = ref.read(onboardingDoneProvider);

      AppLogger.debug(
        'Redirect: path=$currentPath loggedIn=$isLoggedIn '
        'onboarding=$onboardingDone role=$cachedRole',
      );

      // ── 1. Splash → resolve navigation target ────────────────────────────
      if (isOnSplash) {
        if (!onboardingDone) return AppRoutes.onboarding;
        if (!isLoggedIn)     return AppRoutes.phoneAuth;
        return AppRoutes.home;
      }

      // ── 2. Onboarding ────────────────────────────────────────────────────
      if (isOnOnboarding) {
        // Stay on onboarding until the user taps "Get started".
        return null;
      }

      // ── 3. Unauthenticated access ────────────────────────────────────────
      if (!isLoggedIn && !isOnAuth && !isOnSetup) {
        if (!_authPaths.contains(currentPath)) {
          ref.read(pendingDeepLinkProvider.notifier).state = currentPath;
        }
        return AppRoutes.phoneAuth;
      }

      // ── 4. Post sign-in: restore deep link or go to home ─────────────────
      if (isLoggedIn && (isOnAuth || isOnSplash)) {
        if (cachedRole == UserRole.unknown) return null; // still resolving

        final pendingLink = ref.read(pendingDeepLinkProvider.notifier).state;
        if (pendingLink != null) {
          ref.read(pendingDeepLinkProvider.notifier).state = null;

          final isWorkerOnlyPath = pendingLink.startsWith('/worker') &&
              !_workerProfilePattern.hasMatch(pendingLink);

          if (isWorkerOnlyPath && cachedRole == UserRole.client) {
            return AppRoutes.home;
          }
          return pendingLink;
        }
        return AppRoutes.home;
      }

      // ── 5. Role guard: worker-only paths ────────────────────────────────
      if (isLoggedIn && isOnWorkerRoute && cachedRole == UserRole.client) {
        final isWorkerProfilePath = _workerProfilePattern.hasMatch(currentPath);
        if (!isWorkerProfilePath) return AppRoutes.home;
      }

      // ── 6. Normalize /worker-home → /home ───────────────────────────────
      if (isLoggedIn && isOnWorkerHome) return AppRoutes.home;

      return null;
    },

    routes: [
      // ── Splash ─────────────────────────────────────────────────────────
      GoRoute(
        path:        AppRoutes.splash,
        name:        'splash',
        pageBuilder: (_, __) => const NoTransitionPage(child: SplashScreen()),
      ),

      // ── Onboarding ─────────────────────────────────────────────────────
      GoRoute(
        path:        AppRoutes.onboarding,
        name:        'onboarding',
        pageBuilder: (_, s) => _fade(s.pageKey, const OnboardingScreen()),
      ),

      // ── Auth ────────────────────────────────────────────────────────────
      GoRoute(
        path:        AppRoutes.phoneAuth,
        name:        'phone-auth',
        pageBuilder: (_, s) => _fade(s.pageKey, const PhoneAuthScreen()),
      ),

      // ── Account setup ───────────────────────────────────────────────────
      GoRoute(
        path:        AppRoutes.roleSelection,
        name:        'role-selection',
        pageBuilder: (_, s) => _fade(s.pageKey, const RoleSelectionScreen()),
      ),
      GoRoute(
        path:        AppRoutes.userProfileSetup,
        name:        'user-profile-setup',
        pageBuilder: (_, s) => _fade(s.pageKey, const UserProfileScreen()),
      ),
      GoRoute(
        path:        AppRoutes.workerProfileSetup,
        name:        'worker-profile-setup',
        // WorkerProfileSetupScreen — the new-user setup widget (auth folder)
        pageBuilder: (_, s) => _fade(s.pageKey, const WorkerProfileSetupScreen()),
      ),

      // ── Main navigation shell ────────────────────────────────────────────
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => MainNavigationScreen(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path:        AppRoutes.home,
              name:        'home',
              pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path:        AppRoutes.workerJobs,
              name:        'worker-jobs',
              pageBuilder: (_, __) => const NoTransitionPage(child: WorkerJobsScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path:        AppRoutes.settings,
              name:        'settings',
              pageBuilder: (_, __) => const NoTransitionPage(child: SettingsScreen()),
            ),
          ]),
        ],
      ),

      // ── Feature routes ──────────────────────────────────────────────────

      GoRoute(
        path:        AppRoutes.serviceRequest,
        name:        'service-request',
        pageBuilder: (_, s) {
          final extra       = s.extra as Map<String, dynamic>?;
          final isEmergency = extra?['isEmergency'] as bool? ?? false;
          return _fade(s.pageKey, ServiceRequestScreen(isEmergency: isEmergency));
        },
      ),
      GoRoute(
        path:        AppRoutes.workerProfile,
        name:        'worker-profile',
        pageBuilder: (_, s) {
          final workerId = s.pathParameters['id'] ?? '';
          // WorkerProfileScreen — the public viewer (worker_profile folder)
          return _fade(s.pageKey, WorkerProfileScreen(workerId: workerId));
        },
      ),
      GoRoute(
        path:        AppRoutes.editProfile,
        name:        'edit-profile',
        pageBuilder: (_, s) => _fade(s.pageKey, const EditProfileScreen()),
      ),
      GoRoute(
        path:        AppRoutes.notifications,
        name:        'notifications',
        pageBuilder: (_, s) => _fade(s.pageKey, const NotificationsScreen()),
      ),
      GoRoute(
        path:        AppRoutes.about,
        name:        'about',
        pageBuilder: (_, s) => _fade(s.pageKey, const AboutScreen()),
      ),
      GoRoute(
        path:        AppRoutes.help,
        name:        'help',
        pageBuilder: (_, s) => _fade(s.pageKey, const HelpScreen()),
      ),

      // ── Bid model routes ────────────────────────────────────────────────

      GoRoute(
        path:        '/service-request/:id/bids',
        name:        'bids-list',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, BidsListScreen(requestId: s.pathParameters['id'] ?? '')),
      ),
      GoRoute(
        path:        '/service-request/:id/tracking',
        name:        'request-tracking',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, RequestTrackingScreen(requestId: s.pathParameters['id'] ?? '')),
      ),
      GoRoute(
        path:        '/service-request/:id/rating',
        name:        'client-rating',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, RatingScreen(requestId: s.pathParameters['id'] ?? '')),
      ),
      GoRoute(
        path:        '/worker/jobs/:id',
        name:        'worker-job-detail',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, JobDetailScreen(jobId: s.pathParameters['id'] ?? '')),
      ),
      GoRoute(
        path:        '/worker/jobs/:id/bid',
        name:        'submit-bid',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, SubmitBidScreen(requestId: s.pathParameters['id'] ?? '')),
      ),
    ],

    errorBuilder: (context, state) {
      final auth = ref.read(authServiceProvider);
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(context.tr('error.page_not_found'),
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(state.uri.toString(),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () =>
                    context.go(auth.isLoggedIn ? AppRoutes.home : AppRoutes.phoneAuth),
                child: Text(context.tr('error.go_home')),
              ),
            ],
          ),
        ),
      );
    },
  );
});

// ── _UserIdentityListenable ────────────────────────────────────────────────

class _UserIdentityListenable extends ChangeNotifier {
  final AuthService _authService;
  String? _lastUid;

  _UserIdentityListenable(this._authService) {
    _authService.addListener(_onAuthChanged);
    _lastUid = _authService.user?.uid;
  }

  void _onAuthChanged() {
    final newUid = _authService.user?.uid;
    if (newUid != _lastUid) {
      _lastUid = newUid;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authService.removeListener(_onAuthChanged);
    super.dispose();
  }
}

// ── Page transition helper ─────────────────────────────────────────────────

CustomTransitionPage<void> _fade(LocalKey key, Widget child) {
  return CustomTransitionPage<void>(
    key:                       key,
    child:                     child,
    transitionDuration:        const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    transitionsBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(
        parent:       animation,
        curve:        Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    ),
  );
}

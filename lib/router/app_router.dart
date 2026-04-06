// lib/router/app_router.dart
//
// UPDATED: placeholder routes replaced with real screen implementations:
//   editProfile       → EditProfileScreen
//   notifications     → NotificationsScreen
//   about             → AboutScreen
//   help              → HelpScreen
//   workerProfile/:id → WorkerProfileScreen(workerId)
//
// UPDATED: Messaging/chat routes removed — replaced by WhatsApp.
//   Removed: messages branch from StatefulShellRoute
//   Removed: /chat/:id route
//
// Option A: CompositeListenable imported from lib/utils/composite_listenable.dart
// (kept as a shared public utility used by other files in the project).
//
// [LOGIC-APPLY FIX] Role guard — submit-bid route security:
//   The previous client guard checked:
//     isOnWorkerRoute && !currentPath.startsWith('/worker/')
//   This excluded ALL paths beginning with '/worker/' from the guard,
//   intending to allow clients to view /worker/:id (worker profile).
//   But it also allowed clients to reach /worker/jobs/:id/bid — workers-only.
//
//   Fix: replaced the broad exclusion with a precise allowlist.
//   Clients may access paths matching '/worker/:id' (worker profile view).
//   All other /worker/* paths — including /worker/jobs/... — are worker-only.
//   Clients reaching them are redirected to AppRoutes.home.
//
//   The check uses a simple regex: r'^/worker/[^/]+$' which matches
//   /worker/<id> (single segment) and rejects /worker/jobs/<id>/bid etc.
//
// [LOGIC-APPLY FIX] Deep-link restoration after login:
//   Added pendingDeepLinkProvider (StateProvider<String?>) to capture the
//   originally-requested path when the redirect guard pushes a user to /login.
//   After successful auth the redirect reads and clears the stored path,
//   navigating the user to their original destination instead of /home.
//   Auth-specific paths (splash, login, register, forgotPassword,
//   emailVerification) are never stored as pending deep links.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../screens/splash/splash_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/auth/email_verification_screen.dart';
import '../screens/auth/forgot_password_screen.dart';
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
import '../screens/worker_profile/worker_profile_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/about/about_screen.dart';
import '../screens/help/help_screen.dart';
import '../providers/auth_providers.dart';
import '../providers/core_providers.dart';
import '../providers/user_role_provider.dart';
import '../services/auth_service.dart';
import '../utils/composite_listenable.dart';
import '../utils/constants.dart';
import '../utils/localization.dart';
import '../utils/logger.dart';

// ============================================================================
// DEEP-LINK RESTORATION PROVIDER
// ============================================================================

// FIX [AUTO]: stores the path a guest was trying to reach before being
// redirected to /login. After successful authentication the redirect reads and
// clears this value, sending the user to their original destination rather than
// always landing on /home.
//
// Usage (redirect function):
//   • On unauthenticated access: write currentPath → pendingDeepLinkProvider
//   • On successful auth:        read + clear → navigate to stored path
//
// Only non-auth paths are stored (splash / login / register /
// forgotPassword / emailVerification are never treated as deep links).
final pendingDeepLinkProvider = StateProvider<String?>((ref) => null);

// ============================================================================
// ROUTER PROVIDER
// ============================================================================

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

  // [LOGIC-APPLY FIX] Regex for worker-profile paths that clients may access.
  // Matches /worker/<single-segment> only — e.g. /worker/abc123.
  // Does NOT match /worker/jobs/... or any deeper path.
  final _workerProfilePattern = RegExp(r'^/worker/[^/]+$');

  // FIX [AUTO]: auth-specific paths that must never be saved as a pending
  // deep link (storing them would cause a post-login redirect loop).
  const _authPaths = {
    AppRoutes.splash,
    AppRoutes.login,
    AppRoutes.register,
    AppRoutes.forgotPassword,
    AppRoutes.emailVerification,
  };

  return GoRouter(
    initialLocation: AppRoutes.splash,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: listenable,

    redirect: (context, state) {
      final appInitialized = ref.read(appInitializedProvider);
      if (!appInitialized) {
        return state.matchedLocation == AppRoutes.splash
            ? null
            : AppRoutes.splash;
      }

      final isLoggedIn  = authService.isLoggedIn;
      final currentPath = state.matchedLocation;

      final isOnSplash      = currentPath == AppRoutes.splash;
      final isOnAuth        = currentPath == AppRoutes.login ||
          currentPath == AppRoutes.register ||
          currentPath == AppRoutes.forgotPassword;
      final isOnVerify      = currentPath == AppRoutes.emailVerification;
      final isOnWorkerHome  = currentPath == AppRoutes.workerHome;
      final isOnWorkerRoute = currentPath.startsWith('/worker');

      final cachedRole = ref.read(cachedUserRoleProvider);

      AppLogger.debug(
        'Redirect: path=$currentPath loggedIn=$isLoggedIn '
        'emailVerified=${authService.emailVerified} '
        'role=$cachedRole',
      );

      if (isOnSplash) {
        if (isLoggedIn) {
          if (!authService.emailVerified) return AppRoutes.emailVerification;
          return AppRoutes.home;
        }
        return AppRoutes.login;
      }

      if (!isLoggedIn && !isOnAuth) {
        // FIX [AUTO]: capture the originally-requested path so we can restore
        // it after the user successfully authenticates. Auth-specific paths
        // are excluded to prevent post-login redirect loops.
        if (!_authPaths.contains(currentPath)) {
          ref.read(pendingDeepLinkProvider.notifier).state = currentPath;
          AppLogger.debug(
            'Redirect: stored pending deep link → $currentPath',
          );
        }
        return AppRoutes.login;
      }

      if (isLoggedIn && !authService.emailVerified &&
          !isOnVerify && !isOnAuth) {
        return AppRoutes.emailVerification;
      }

      if (isLoggedIn && authService.emailVerified && isOnVerify) {
        return AppRoutes.home;
      }

      if (isLoggedIn && isOnAuth) {
        if (cachedRole == UserRole.unknown) return null;

        // FIX [AUTO]: after successful auth, restore the pending deep link if
        // one was captured before the login redirect. Clear it regardless so
        // it is not accidentally replayed on a future navigation event.
        final pendingLink =
            ref.read(pendingDeepLinkProvider.notifier).state;
        if (pendingLink != null) {
          ref.read(pendingDeepLinkProvider.notifier).state = null;
          AppLogger.info(
            'Redirect: restoring pending deep link → $pendingLink',
          );
          // Role guard: workers-only paths must not be restored for clients.
          final isWorkerOnlyPath =
              pendingLink.startsWith('/worker') &&
              !_workerProfilePattern.hasMatch(pendingLink);
          if (isWorkerOnlyPath && cachedRole == UserRole.client) {
            AppLogger.debug(
              'Redirect: pending deep link $pendingLink is worker-only — '
              'redirecting client to /home instead',
            );
            return AppRoutes.home;
          }
          return pendingLink;
        }

        return AppRoutes.home;
      }

      // [LOGIC-APPLY FIX] Tightened role guard for worker routes.
      //
      // OLD guard: blocked /worker-* routes but exempted ALL /worker/* paths
      //   with `!currentPath.startsWith('/worker/')`. This inadvertently
      //   allowed clients to reach /worker/jobs/:id/bid.
      //
      // NEW guard: clients may only access paths matching the worker-profile
      //   pattern (/worker/<id>). All other /worker/* paths — including
      //   /worker/jobs/:id, /worker/jobs/:id/bid — are worker-only.
      //
      // The guard still allows /worker-jobs (branch route) to be handled by
      // the nav-bar visibility logic rather than a hard redirect, so we only
      // apply the strict path block inside the /worker/* namespace.
      if (isLoggedIn &&
          isOnWorkerRoute &&
          cachedRole == UserRole.client) {
        final isWorkerProfilePath = _workerProfilePattern.hasMatch(currentPath);
        if (!isWorkerProfilePath) {
          return AppRoutes.home;
        }
      }

      // Redirect /worker-home to /home — unified screen
      if (isLoggedIn && isOnWorkerHome) return AppRoutes.home;

      return null;
    },

    routes: [
      // ── Splash ─────────────────────────────────────────────────────────────
      GoRoute(
        path: AppRoutes.splash,
        name: 'splash',
        pageBuilder: (_, __) =>
            const NoTransitionPage(child: SplashScreen()),
      ),

      // ── Auth ────────────────────────────────────────────────────────────────
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        pageBuilder: (_, s) => _fade(s.pageKey, const LoginScreen()),
      ),
      GoRoute(
        path: AppRoutes.register,
        name: 'register',
        pageBuilder: (_, s) => _fade(s.pageKey, const RegisterScreen()),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        name: 'forgot-password',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: AppRoutes.emailVerification,
        name: 'email-verification',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, const EmailVerificationScreen()),
      ),

      // ── Main Navigation Shell ────────────────────────────────────────────────
      //
      //   Branch index  Path            Visible to
      //   ──────────────────────────────────────────
      //   0             /home           all
      //   1             /worker-jobs    worker only
      //   2             /settings       all
      //
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) =>
            MainNavigationScreen(navigationShell: shell),
        branches: [
          // Branch 0 — Home (client + worker unified)
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoutes.home,
              name: 'home',
              pageBuilder: (_, __) =>
                  const NoTransitionPage(child: HomeScreen()),
            ),
          ]),
          // Branch 1 — Worker Jobs (worker only — hidden from client via nav bar)
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoutes.workerJobs,
              name: 'worker-jobs',
              pageBuilder: (_, __) =>
                  const NoTransitionPage(child: WorkerJobsScreen()),
            ),
          ]),
          // Branch 2 — Settings (shared)
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoutes.settings,
              name: 'settings',
              pageBuilder: (_, __) =>
                  const NoTransitionPage(child: SettingsScreen()),
            ),
          ]),
        ],
      ),

      // =======================================================================
      // FEATURE ROUTES (full-screen, no bottom nav)
      // =======================================================================

      GoRoute(
        path: AppRoutes.serviceRequest,
        name: 'service-request',
        pageBuilder: (_, s) {
          final extra       = s.extra as Map<String, dynamic>?;
          final isEmergency = extra?['isEmergency'] as bool? ?? false;
          return _fade(s.pageKey,
              ServiceRequestScreen(isEmergency: isEmergency));
        },
      ),

      // Worker profile — real screen, workerId from path parameter.
      // Accessible to both roles — clients view worker profiles before
      // selecting a bid. Pattern: /worker/:id (single segment only).
      GoRoute(
        path: AppRoutes.workerProfile,
        name: 'worker-profile',
        pageBuilder: (_, s) {
          final workerId = s.pathParameters['id'] ?? '';
          return _fade(s.pageKey, WorkerProfileScreen(workerId: workerId));
        },
      ),

      // Edit profile — real screen.
      GoRoute(
        path: AppRoutes.editProfile,
        name: 'edit-profile',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, const EditProfileScreen()),
      ),

      // Notification preferences — real screen.
      GoRoute(
        path: AppRoutes.notifications,
        name: 'notifications',
        pageBuilder: (_, s) =>
            _fade(s.pageKey, const NotificationsScreen()),
      ),

      // About — real screen.
      GoRoute(
        path: AppRoutes.about,
        name: 'about',
        pageBuilder: (_, s) => _fade(s.pageKey, const AboutScreen()),
      ),

      // Help — real screen.
      GoRoute(
        path: AppRoutes.help,
        name: 'help',
        pageBuilder: (_, s) => _fade(s.pageKey, const HelpScreen()),
      ),

      // =======================================================================
      // HYBRID BID MODEL — 4 ROUTES
      // =======================================================================

      GoRoute(
        path: '/service-request/:id/bids',
        name: 'bids-list',
        pageBuilder: (_, s) => _fade(
          s.pageKey,
          BidsListScreen(requestId: s.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/service-request/:id/tracking',
        name: 'request-tracking',
        pageBuilder: (_, s) => _fade(
          s.pageKey,
          RequestTrackingScreen(requestId: s.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/service-request/:id/rating',
        name: 'client-rating',
        pageBuilder: (_, s) => _fade(
          s.pageKey,
          RatingScreen(requestId: s.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/worker/jobs/:id',
        name: 'worker-job-detail',
        pageBuilder: (_, s) => _fade(
          s.pageKey,
          JobDetailScreen(jobId: s.pathParameters['id'] ?? ''),
        ),
      ),

      // [LOGIC-APPLY FIX] submit-bid route — worker-only.
      // The redirect guard now blocks clients from /worker/jobs/* paths,
      // so a client who deep-links or guesses this URL is redirected to
      // /home before this pageBuilder ever runs. The guard is the
      // authoritative enforcement point; the route definition is unchanged.
      GoRoute(
        path: '/worker/jobs/:id/bid',
        name: 'submit-bid',
        pageBuilder: (_, s) => _fade(
          s.pageKey,
          SubmitBidScreen(requestId: s.pathParameters['id'] ?? ''),
        ),
      ),
    ],

    // FIX (Auth Security P1): errorBuilder resolves destination directly
    // from auth state — avoids a double redirect flash.
    errorBuilder: (context, state) {
      final auth = ref.read(authServiceProvider);
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size:  64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                context.tr('error.page_not_found'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                state.uri.toString(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.go(
                  auth.isLoggedIn ? AppRoutes.home : AppRoutes.login,
                ),
                child: Text(context.tr('error.go_home')),
              ),
            ],
          ),
        ),
      );
    },
  );
});

// ============================================================================
// _UserIdentityListenable
// ============================================================================

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

// ============================================================================
// PAGE TRANSITION HELPER
// ============================================================================

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

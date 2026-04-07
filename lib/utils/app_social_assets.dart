// lib/utils/app_social_assets.dart
//
// Centralises SVG asset paths for the three social sign-in providers.
// Used by social_button_widgets.dart via SvgPicture.asset().
//
// SVG files must be placed at the paths below and declared in pubspec.yaml:
//
//   flutter:
//     assets:
//       - assets/images/social/
//
// Each SVG must conform to the provider's official brand guidelines:
//   • Google  — https://developers.google.com/identity/branding-guidelines
//   • Meta    — https://developers.facebook.com/docs/facebook-login/userexperience/
//   • Apple   — https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple
//
// TODO(manual): Download official SVGs and place them at the paths below.
//               Run `flutter pub get` after adding flutter_svg: ^2.0.10+1.

class AppSocialAssets {
  AppSocialAssets._();

  static const String _base = 'assets/images/social';

  /// Official Google "G" logo SVG.
  /// Source: https://developers.google.com/identity/branding-guidelines
  static const String google = '$_base/google.svg';

  /// Official Facebook "f" logo SVG (white on blue circle).
  /// Source: https://developers.facebook.com/docs/facebook-login/userexperience/
  static const String facebook = '$_base/facebook.svg';

  /// Official Apple logo SVG (monochrome — adapt fill colour per theme).
  /// Source: https://developer.apple.com/design/downloads/
  static const String apple = '$_base/apple.svg';
}

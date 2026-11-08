/// Links baked into the app at build time from `--dart-define-from-file=.env`
/// (see `.env.example`).
abstract final class AppLinks {
  /// The community chat. Empty hides Help › Join community.
  static const community = String.fromEnvironment('COMMUNITY_URL');
}

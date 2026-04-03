abstract class AbstractSaslHandler {
  Future<AuthenticationResult> start();
}

class AuthenticationResult {
  bool successful;
  String message;
  bool retryWithFreshFeatures;

  AuthenticationResult(
    this.successful,
    this.message, {
    this.retryWithFreshFeatures = false,
  });
}

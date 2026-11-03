/// Public address and reserved API port needed by access use cases.
abstract interface class AccessEnvironment {
  int get port;
  Uri get webOrigin;
}

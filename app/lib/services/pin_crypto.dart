import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Salted hashing for the permanent "anytime access" PIN.
///
/// The host stores only `salt` + `hash` (never the plaintext PIN) and sends them
/// to the server when arming. The server validates a viewer's PIN attempt with
/// the SAME `sha256(salt + pin)` (Node's crypto) — so the algorithm must match
/// exactly: hex-encoded SHA-256 of the salt string concatenated with the PIN.
class PinCrypto {
  /// A random hex salt (16 bytes → 32 hex chars).
  static String generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// `sha256(salt + pin)` as a lowercase hex string. Matches server `hashPin`.
  static String hash(String salt, String pin) {
    final digest = sha256.convert(utf8.encode(salt + pin));
    return digest.toString();
  }
}

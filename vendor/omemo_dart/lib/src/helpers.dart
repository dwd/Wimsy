import 'dart:convert';
import 'dart:math';

/// Flattens [inputs] and concatenates the elements.
List<int> concat(List<List<int>> inputs) {
  final tmp = List<int>.empty(growable: true);
  for (final input in inputs) {
    tmp.addAll(input);
  }

  return tmp;
}

/// Compares the two lists [a] and [b] and return true if [a] and [b] are index-by-index
/// equal. Returns false, if they are not "equal";
bool listsEqual<T>(List<T> a, List<T> b) {
  // TODO(Unknown): Do we need to use a constant time comparison?
  if (a.length != b.length) return false;

  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }

  return true;
}

/// Use Dart's cryptographically secure random number generator at Random.secure()
/// to generate [length] random numbers between 0 and 256 exclusive.
List<int> generateRandomBytes(int length) {
  final bytes = List<int>.empty(growable: true);
  final r = Random.secure();
  for (var i = 0; i < length; i++) {
    bytes.add(r.nextInt(256));
  }

  return bytes;
}

/// Generate a random number between 0 inclusive and 2**31 - 1 exclusive
/// (i.e. 0 to 2147483646 inclusive).
///
/// This is used for OMEMO device ids and signed/one-time prekey ids, which
/// are serialized as plain XML integer attributes (`sid`, `rid`,
/// `signedPreKeyId`, `preKeyId`, ...). While XEP-0384 itself doesn't
/// constrain these to fit in a *signed* 32-bit integer, several real-world
/// implementations (e.g. Dino's xmpp-vala, via `StanzaNode.get_attribute_int`)
/// parse them as such. Generating a value in the full unsigned 32-bit range
/// (as this function used to do) therefore has roughly a 50% chance of
/// producing an id those clients cannot parse, silently breaking OMEMO
/// interoperability with them (manifesting e.g. as Dino logging "Can't
/// parse OMEMO node: No sid" and failing to decrypt/discover devices).
int generateRandom32BitNumber() {
  return Random.secure().nextInt(2147483647 /*pow(2, 31) - 1*/);
}

/// Describes the differences between two lists in terms of its items.
class ListDiff<T> {
  ListDiff(this.added, this.removed);

  /// The items that were added.
  final List<T> added;

  /// The items that were removed.
  final List<T> removed;
}

extension AppendToListOrCreateExtension<K, V> on Map<K, List<V>> {
  /// Create or append [value] to the list identified with key [key].
  void appendOrCreate(K key, V value, {bool checkExistence = false}) {
    if (containsKey(key)) {
      if (!checkExistence) {
        this[key]!.add(value);
      }
      if (!this[key]!.contains(value)) {
        this[key]!.add(value);
      }
    } else {
      this[key] = [value];
    }
  }
}

extension StringFromBase64Extension on String {
  /// Base64-decode this string. Useful for doing `someString?.fromBase64()` instead
  /// of `someString != null ? base64Decode(someString) : null`.
  List<int> fromBase64() => base64Decode(this);
}

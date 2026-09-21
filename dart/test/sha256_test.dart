import 'dart:convert';

import 'package:namida_party_relay/src/ids.dart';
import 'package:namida_party_relay/src/sha256.dart';
import 'package:test/test.dart';

void main() {
  test('known vectors', () {
    const vectors = <String, String>{
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      // -- 56 and 112 bytes, the two padding edge cases
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq': '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu':
          'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
    };
    vectors.forEach((message, digest) {
      expect(sha256Hex(utf8.encode(message)), digest, reason: '"$message"');
    });
    expect(sha256(utf8.encode('abc')), hasLength(32));
    expect(sha256Hex(utf8.encode('a' * 1000000)), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
  });

  test('hid is the first 8 hex of the identity digest', () {
    expect(identityHid('did-creator-a'), '58ba2f1a');
    expect(identityHid('did-creator-a'), sha256Hex(utf8.encode('did-creator-a')).substring(0, 8));
    expect(identityHid(''), hasLength(8));
    expect(identityHid('did-creator-a'), isNot(identityHid('did-creator-b')));
  });
}

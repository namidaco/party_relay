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

  test('hmac-sha256 rfc 4231 vectors', () {
    List<int> filled(int length, int byte) => List<int>.filled(length, byte);
    final longKey = filled(131, 0xaa);
    final vectors = <(List<int>, List<int>, String)>[
      (filled(20, 0x0b), utf8.encode('Hi There'), 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7'),
      (utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'), '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'),
      (filled(20, 0xaa), filled(50, 0xdd), '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe'),
      (List<int>.generate(25, (i) => i + 1), filled(50, 0xcd), '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b'),
      (longKey, utf8.encode('Test Using Larger Than Block-Size Key - Hash Key First'), '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54'),
      (
        longKey,
        utf8.encode('This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.'),
        '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
      ),
    ];
    for (final (key, message, mac) in vectors) {
      expect(hmacSha256Hex(key, message), mac);
    }
    // -- case 5 is truncated to 128 bits
    expect(hmacSha256Hex(filled(20, 0x0c), utf8.encode('Test With Truncation'), 16), 'a3b6167473100ee06e0c796c2955552b');
    expect(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?')), hasLength(32));
  });

  test('hid is the first 8 hex of the keyed identity digest', () {
    final key = utf8.encode('secret');
    expect(identityHid(key, 'did-creator-a'), '4e36f999');
    expect(identityHid(key, 'did-creator-a'), hmacSha256Hex(key, utf8.encode('did-creator-a')).substring(0, 8));
    expect(identityHid(key, 'did-creator-a'), isNot(sha256Hex(utf8.encode('did-creator-a')).substring(0, 8)), reason: 'not the bare identity digest');
    expect(identityHid(key, ''), hasLength(8));
    expect(identityHid(key, 'did-creator-a'), isNot(identityHid(key, 'did-creator-b')));
    expect(identityHid(utf8.encode('other'), 'did-creator-a'), isNot(identityHid(key, 'did-creator-a')));
  });
}

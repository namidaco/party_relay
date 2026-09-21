import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  test('info', () async {
    final result = await relay.getInfo();
    expect(result.status, 200);
    expect(result.body['ev'], kEnvelopeVersion);
    expect(result.body['name'], kRelayName);
    expect(result.body['membership'], false);
    expect(result.body['createPassword'], false);
  });

  test('create returns a code of the right alphabet', () async {
    final room = await relay.createRoom(name: 'host');
    expect(room.code.length, kRoomCodeLength);
    expect(RegExp('^[$kRoomCodeAlphabet]{$kRoomCodeLength}\$').hasMatch(room.code), isTrue, reason: room.code);
    expect(room.token, isNotEmpty);
    expect(room.max, greaterThan(0));
    expect(room.tier, isNotEmpty);
    expect(normalizeRoomCode(room.code), room.code);
  });

  test('create validation', () async {
    Future<void> rejects(Object? body, {String reason = ''}) async {
      final result = await relay.postRoom(body);
      expect(result.status, 400, reason: '$reason -> ${result.status} ${result.body}');
      expect(result.error, RelayErrors.badRequest, reason: reason);
    }

    Map<String, Object?> body({Object? pv = 1, Object? name = 'host', Object? did = 'device', Object? opts}) => {
          'pv': pv,
          'name': name,
          'did': did,
          if (opts != null) 'opts': opts,
        };

    await rejects('not an object', reason: 'body');
    await rejects(body(pv: null), reason: 'pv null');
    await rejects(body(pv: 0), reason: 'pv 0');
    await rejects(body(pv: '1'), reason: 'pv string');
    await rejects(body(name: ''), reason: 'empty name');
    await rejects(body(name: '    '), reason: 'blank name');
    await rejects(body(name: '\u0001\u0002'), reason: 'control only name');
    await rejects(body(name: 'x' * 33), reason: 'long name');
    await rejects(body(name: 12), reason: 'name type');
    await rejects(body(did: ''), reason: 'empty did');
    await rejects(body(did: 'd' * 65), reason: 'long did');
    await rejects(body(did: 7), reason: 'did type');
    await rejects(body(opts: {'approval': 'yes'}), reason: 'approval type');
    await rejects(body(opts: {'password': ''}), reason: 'empty password');
    await rejects(body(opts: {'password': 'p' * 65}), reason: 'long password');
    await rejects(body(opts: 'nope'), reason: 'opts type');

    final ok = await relay.postRoom(body(name: '  spaced  ', opts: {'approval': false, 'password': null}));
    expect(ok.status, 200);
  });

  test('room codes are case insensitive on connect', () async {
    final room = await relay.createRoom();
    final client = await relay.join(room.code.toLowerCase(), token: room.token);
    expect(client.n, 1);
    await client.close();
  });

  test('unknown room does not upgrade', () async {
    for (final code in ['ZZZZZZZZ', 'AAAAAAA0', 'SHORT', 'way-too-long-code']) {
      final result = await relay.upgrade(code);
      expect(result, isA<HttpResult>(), reason: code);
      expect((result as HttpResult).status, 404, reason: code);
      expect(result.error, RelayErrors.notFound, reason: code);
    }
  });
}

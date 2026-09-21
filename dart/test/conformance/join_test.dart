import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  test('join timeout closes the socket', () async {
    final room = await relay.createRoom();
    final client = await relay.connect(room.code);
    await client.expectFatal(RelayErrors.timeout, const Duration(milliseconds: kJoinTimeoutMs * 4));
  });

  test('welcome shape and members list', () async {
    final room = await relay.createRoom(name: 'the host');
    final host = await relay.join(room.code, name: 'the host', token: room.token);
    expect(host.n, 1);
    expect(host.welcome!['host'], 1);
    expect(host.welcome!['hostOnline'], true);
    expect(host.welcome!['pv'], 1);
    expect(host.welcome!['max'], room.max);
    expect(host.welcome!['now'], isA<int>());
    expect(host.welcome!['token'], isNotEmpty);
    expect(host.welcome!['opts'], {'approval': false, 'password': false, 'locked': false, 'public': false});
    expect(host.welcome!['members'], [
      {'n': 1, 'name': 'the host'},
    ]);

    final guest = await relay.join(room.code, name: '  padded  ');
    expect(guest.n, 2);
    expect(guest.welcome!['host'], 1);
    expect(guest.welcome!['hostOnline'], true);
    expect(guest.welcome!['members'], [
      {'n': 1, 'name': 'the host'},
      {'n': 2, 'name': 'padded'},
    ]);

    final joined = await host.expectFrame(Ctrl.joined);
    expect(joined['n'], 2);
    expect(joined['name'], 'padded');
    await host.expectSilence();
  });

  test('version mismatch carries the room pv', () async {
    final room = await relay.createRoom(pv: 7);
    final client = await relay.connect(room.code);
    final frame = await client.joinRaw(pv: 3);
    expect(frame['t'], Ctrl.error);
    expect(frame['code'], RelayErrors.versionMismatch);
    expect(frame['fatal'], true);
    expect(frame['pv'], 7);
    await client.done;
  });

  test('malformed joins are fatal', () async {
    final room = await relay.createRoom();
    Future<void> rejects(void Function(TestClient c) send) async {
      final client = await relay.connect(room.code);
      send(client);
      await client.expectFatal(RelayErrors.badRequest);
    }

    await rejects((c) => c.sendText('not json'));
    await rejects((c) => c.send({'t': Ctrl.ping}));
    await rejects((c) => c.send({'t': Ctrl.join, 'pv': 1, 'did': 'd'}));
    await rejects((c) => c.send({'t': Ctrl.join, 'pv': 1, 'name': 'n' * 33, 'did': 'd'}));
    await rejects((c) => c.send({'t': Ctrl.join, 'pv': 1, 'name': 'ok', 'did': ''}));
    await rejects((c) => c.send({'t': Ctrl.join, 'pv': '1', 'name': 'ok', 'did': 'd'}));
    await rejects((c) => c.send({'t': Ctrl.join, 'pv': 1, 'name': 'ok', 'did': 'd', 'token': 12}));
  });

  test('password rooms', () async {
    final room = await relay.createRoom(password: 'hunter2');
    final host = await relay.join(room.code, token: room.token);
    expect(host.welcome!['opts'], {'approval': false, 'password': true, 'locked': false, 'public': false});

    final wrong = await relay.connect(room.code);
    wrong.send({'t': Ctrl.join, 'pv': 1, 'name': 'guest', 'did': 'bad-pass', 'password': 'nope'});
    await wrong.expectFatal(RelayErrors.badPassword);

    final missing = await relay.connect(room.code);
    missing.send({'t': Ctrl.join, 'pv': 1, 'name': 'guest', 'did': 'no-pass'});
    await missing.expectFatal(RelayErrors.badPassword);

    final guest = await relay.join(room.code, password: 'hunter2');
    expect(guest.welcome!['opts'], {'approval': false, 'password': true, 'locked': false, 'public': false});
  });

  test('full room', () async {
    final room = await relay.createRoom();
    if (room.max > 32) {
      markTestSkipped('relay max is ${room.max}, set MAX_MEMBERS=$kConformanceMaxMembers');
      return;
    }
    final host = await relay.join(room.code, token: room.token);
    expect(host.n, 1);
    for (var i = 1; i < room.max; i++) {
      await relay.join(room.code, name: 'guest $i');
    }
    final extra = await relay.connect(room.code);
    extra.send({'t': Ctrl.join, 'pv': 1, 'name': 'late', 'did': 'late'});
    await extra.expectFatal(RelayErrors.full);
  });

  test('invalid token is treated as none', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, token: room.token);
    final guest = await relay.join(room.code, token: 'definitely-not-a-token');
    expect(guest.n, 2);
    await host.expectFrame(Ctrl.joined);
  });

  test('token resume keeps n and replaces the old socket', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, token: room.token);
    final first = await relay.join(room.code, name: 'guest', did: 'stable-did');
    await host.expectFrame(Ctrl.joined);

    final second = await relay.connect(room.code);
    final welcome = await second.join(name: 'guest', did: 'stable-did', token: first.token);
    expect(welcome['n'], first.n);

    final replaced = await first.nextText();
    expect(replaced['t'], Ctrl.left);
    expect(replaced['r'], LeftReason.replaced);
    await first.done;

    // -- the member never left, so nobody hears about it
    await host.expectSilence();
  });

  test('resume after a lost socket re-announces the member', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, token: room.token);
    final guest = await relay.join(room.code, name: 'ghost', did: 'ghost-did');
    await host.expectFrame(Ctrl.joined);
    final token = guest.token!;
    final n = guest.n;

    await guest.close();
    final left = await host.expectFrame(Ctrl.left);
    expect(left['n'], n);
    expect(left['r'], LeftReason.lost);

    final back = await relay.join(room.code, name: 'ghost', did: 'ghost-did', token: token);
    expect(back.n, n);
    final joined = await host.expectFrame(Ctrl.joined);
    expect(joined['n'], n);
    expect(joined['name'], 'ghost');
  });

  test('leave is broadcast with its reason', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, token: room.token);
    final guest = await relay.join(room.code);
    await host.expectFrame(Ctrl.joined);
    guest.send({'t': Ctrl.leave});
    final left = await host.expectFrame(Ctrl.left);
    expect(left['n'], guest.n);
    expect(left['r'], LeftReason.leave);
    await guest.done;
  });

  test('ping pong', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, token: room.token);
    host.send({'t': Ctrl.ping, 'c': 4242});
    final pong = await host.expectFrame(Ctrl.pong);
    expect(pong['c'], 4242);
    expect(pong['s'], isA<int>());
  });
}

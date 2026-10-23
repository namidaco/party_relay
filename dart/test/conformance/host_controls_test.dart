import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  Future<(CreatedRoom, TestClient, TestClient, TestClient)> party() async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final a = await relay.join(room.code, name: 'a', did: 'did-a');
    final b = await relay.join(room.code, name: 'b', did: 'did-b');
    await host.expectFrame(Ctrl.joined);
    await host.expectFrame(Ctrl.joined);
    await a.expectFrame(Ctrl.joined);
    return (room, host, a, b);
  }

  test('host controls are forbidden for guests', () async {
    final (room, host, a, b) = await party();
    final frames = <Map<String, Object?>>[
      {'t': Ctrl.kick, 'n': 3, 'ban': false},
      {'t': Ctrl.unban, 'id': 'x'},
      {'t': Ctrl.approve, 'r': 'x', 'ok': true},
      {'t': Ctrl.transfer, 'n': 1},
      {'t': Ctrl.successors, 'ns': <int>[]},
      {'t': Ctrl.opts, 'locked': true},
      {'t': Ctrl.close},
    ];
    for (final frame in frames) {
      a.send(frame);
      await a.expectError(RelayErrors.forbidden, fatal: false);
    }
    await b.expectSilence();
    await host.expectSilence();
    // -- none of it went through
    final fresh = await relay.join(room.code, name: 'fresh', did: 'did-fresh');
    expect(fresh.welcome!['opts'], {'approval': false, 'password': false, 'locked': false, 'public': false});
  });

  test('kick revokes the token', () async {
    final (room, host, a, b) = await party();
    host.send({'t': Ctrl.kick, 'n': a.n, 'ban': false});
    await a.expectFatal(RelayErrors.kicked);
    for (final client in [host, b]) {
      final left = await client.expectFrame(Ctrl.left);
      expect(left['n'], a.n);
      expect(left['r'], LeftReason.kick);
    }

    final back = await relay.join(room.code, name: 'a', did: 'did-a', token: a.token);
    expect(back.n, greaterThan(b.n), reason: 'a revoked token must start a fresh member');
    await host.expectFrame(Ctrl.joined);
  });

  test('ban, bans list and unban', () async {
    final (room, host, a, b) = await party();
    host.send({'t': Ctrl.kick, 'n': a.n, 'ban': true});
    await a.expectFatal(RelayErrors.banned);
    expect((await b.expectFrame(Ctrl.left))['r'], LeftReason.ban);
    expect((await host.expectFrame(Ctrl.left))['r'], LeftReason.ban);

    final bans = await host.expectFrame(Ctrl.bans);
    final list = bans['list'] as List<dynamic>;
    expect(list.length, 1);
    final entry = list.first as Map<String, dynamic>;
    expect(entry['id'], isA<String>());
    expect(entry['name'], 'a');

    final rejoin = await relay.connect(room.code);
    rejoin.send({'t': Ctrl.join, 'pv': 1, 'name': 'a', 'did': 'did-a'});
    await rejoin.expectFatal(RelayErrors.banned);

    // -- the host gets the list again right after a welcome
    await host.close();
    final hostBack = await relay.join(room.code, name: 'host', token: room.token);
    expect((await hostBack.expectFrame(Ctrl.bans))['list'], hasLength(1));

    hostBack.send({'t': Ctrl.unban, 'id': entry['id']});
    expect((await hostBack.expectFrame(Ctrl.bans))['list'], isEmpty);

    final allowed = await relay.join(room.code, name: 'a again', did: 'did-a');
    expect(allowed.n, greaterThan(b.n));
  });

  test('a ban covers every member and pending join of the device', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final a = await relay.join(room.code, name: 'a', did: 'did-a');
    final twin = await relay.join(room.code, name: 'twin', did: 'did-a');
    final away = await relay.join(room.code, name: 'away', did: 'did-a');
    for (var i = 0; i < 3; i++) {
      await host.expectFrame(Ctrl.joined);
    }
    host.send({'t': Ctrl.opts, 'approval': true});
    await host.expectFrame(Ctrl.opts);
    await away.close();
    await host.waitFor(Ctrl.left, (f) => f['n'] == away.n);

    final sameDevice = await relay.connect(room.code);
    expect((await sameDevice.joinRaw(name: 'again', did: 'did-a'))['t'], Ctrl.pending);
    final sameDeviceRequest = await host.expectFrame(Ctrl.joinreq);
    final sameIp = await relay.connect(room.code);
    expect((await sameIp.joinRaw(name: 'neighbour', did: 'did-neighbour'))['t'], Ctrl.pending);
    final sameIpRequest = await host.expectFrame(Ctrl.joinreq);

    host.send({'t': Ctrl.kick, 'n': a.n, 'ban': true});
    for (final client in [a, twin]) {
      final error = await client.waitFor(Ctrl.error);
      expect(error['code'], RelayErrors.banned);
      expect(error['fatal'], true);
      await client.done.timeout(kFrameTimeout);
    }
    await sameDevice.expectFatal(RelayErrors.banned);
    expect(await host.expectFrame(Ctrl.left), {'t': Ctrl.left, 'n': a.n, 'r': LeftReason.ban});
    expect(await host.expectFrame(Ctrl.left), {'t': Ctrl.left, 'n': twin.n, 'r': LeftReason.ban});
    expect((await host.expectFrame(Ctrl.joinreqgone))['r'], sameDeviceRequest['r']);
    expect((await host.expectFrame(Ctrl.bans))['list'], hasLength(1));

    for (final token in [twin.token, away.token]) {
      final back = await relay.connect(room.code);
      back.send({'t': Ctrl.join, 'pv': 1, 'name': 'back', 'did': 'did-a', 'token': token});
      await back.expectFatal(RelayErrors.banned);
    }
    host.send({'t': Ctrl.approve, 'r': sameIpRequest['r'], 'ok': true});
    expect((await sameIp.expectFrame(Ctrl.welcome))['n'], greaterThan(away.n));
  });

  test('transfer moves host rights', () async {
    final (room, host, a, b) = await party();
    host.send({'t': Ctrl.transfer, 'n': a.n});
    for (final client in [host, a, b]) {
      final frame = await client.expectFrame(Ctrl.host);
      expect(frame['n'], a.n);
      expect(frame['online'], true);
    }
    host.send({'t': Ctrl.opts, 'locked': true});
    await host.expectError(RelayErrors.forbidden, fatal: false);

    a.send({'t': Ctrl.kick, 'n': b.n, 'ban': false});
    await b.expectFatal(RelayErrors.kicked);
    expect((await host.expectFrame(Ctrl.left))['r'], LeftReason.kick);
    expect(room.code, isNotEmpty);
  });

  test('opts are a partial update, locked blocks new joins only', () async {
    final (room, host, a, b) = await party();
    host.send({'t': Ctrl.opts, 'password': 'secret'});
    for (final client in [host, a, b]) {
      final frame = await client.expectFrame(Ctrl.opts);
      expect(frame['approval'], false);
      expect(frame['password'], true);
      expect(frame['locked'], false);
    }

    host.send({'t': Ctrl.opts, 'locked': true, 'password': null});
    for (final client in [host, a, b]) {
      final frame = await client.expectFrame(Ctrl.opts);
      expect(frame['approval'], false);
      expect(frame['password'], false);
      expect(frame['locked'], true);
    }

    final latecomer = await relay.connect(room.code);
    latecomer.send({'t': Ctrl.join, 'pv': 1, 'name': 'late', 'did': 'did-late'});
    await latecomer.expectFatal(RelayErrors.locked);

    // -- a token resume is still allowed
    await a.close();
    await host.expectFrame(Ctrl.left);
    await b.expectFrame(Ctrl.left);
    final resumed = await relay.join(room.code, name: 'a', did: 'did-a', token: a.token);
    expect(resumed.n, a.n);
    expect(resumed.welcome!['opts'], {'approval': false, 'password': false, 'locked': true, 'public': false});
  });

  test('close ends the room', () async {
    final (room, host, a, b) = await party();
    host.send({'t': Ctrl.close});
    for (final client in [host, a, b]) {
      final frame = await client.expectFrame(Ctrl.closed);
      expect(frame['r'], ClosedReason.host);
      await client.done;
    }
    final result = await relay.upgrade(room.code);
    expect(result, isA<HttpResult>());
    expect((result as HttpResult).status, 404);
    expect(result.error, RelayErrors.notFound);
  });
}

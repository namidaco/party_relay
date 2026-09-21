import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'conformance/harness.dart';

void main() {
  test('programmatic createRoom hosts a room without http', () async {
    final relay = await RelayTarget.start(local: true);
    addTearDown(relay.dispose);
    final created = relay.server!.createRoom(name: '  in app host  ', did: 'device-1', approval: true, maxMembers: 3);
    expect(normalizeRoomCode(created.code), created.code);
    expect(created.token, isNotEmpty);
    expect(created.max, 3);
    expect(created.tier, RelayTier.selfhost);

    final host = await relay.join(created.code, name: 'in app host', token: created.token);
    expect(host.n, 1);
    expect(host.welcome!['host'], 1);
    expect(host.welcome!['max'], 3);
    expect(host.welcome!['opts'], {'approval': true, 'password': false, 'locked': false});

    expect(() => relay.server!.createRoom(name: '', did: 'd'), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: ''), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: 'd', pv: 0), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: 'd', password: ''), throwsArgumentError);
  });

  test('create password gates http creation', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(createPassword: 'let-me-in'), local: true);
    addTearDown(relay.dispose);

    expect((await relay.getInfo()).body['createPassword'], true);
    expect((await relay.getInfo()).body['membership'], false);

    Map<String, Object?> body(Object? auth) => {'pv': 1, 'name': 'host', 'did': 'd', if (auth != null) 'auth': auth};

    var result = await relay.postRoom(body(null));
    expect(result.status, 401);
    expect(result.error, RelayErrors.membershipRequired);

    result = await relay.postRoom(body({'kind': AuthKind.patreon, 'token': 'whatever'}));
    expect(result.status, 401);
    expect(result.error, RelayErrors.membershipRequired);

    result = await relay.postRoom(body({'kind': AuthKind.password, 'password': 'nope'}));
    expect(result.status, 403);
    expect(result.error, RelayErrors.badPassword);

    result = await relay.postRoom(body({'kind': AuthKind.password, 'password': 'let-me-in'}));
    expect(result.status, 200);
    expect(result.body['tier'], RelayTier.selfhost);
  });

  test('membership auth kinds are ignored when no password is set', () async {
    final relay = await RelayTarget.start(local: true);
    addTearDown(relay.dispose);
    final auth = {'kind': AuthKind.supabase, 'id': 'x', 'email': 'y'};
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd', 'auth': auth});
    expect(result.status, 200);
  });

  test('the total rooms cap is enforced', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(maxRoomsTotal: 2), local: true);
    addTearDown(relay.dispose);
    await relay.createRoom();
    await relay.createRoom();
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'});
    expect(result.status, 429);
    expect(result.error, RelayErrors.roomsLimit);
    expect(() => relay.server!.createRoom(name: 'host', did: 'd'), throwsStateError);
  });

  test('create is rate limited per ip', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(createLimit: 3), local: true);
    addTearDown(relay.dispose);
    for (var i = 0; i < 3; i++) {
      expect((await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'})).status, 200);
    }
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'});
    expect(result.status, 429);
    expect(result.error, RelayErrors.rateLimited);
  });

  test('join is rate limited per ip', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(joinLimit: 2), local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    await relay.join(room.code, name: 'host', token: room.token);
    await relay.join(room.code, name: 'a');
    final third = await relay.connect(room.code);
    third.send({'t': Ctrl.join, 'pv': 1, 'name': 'c', 'did': 'did-c'});
    await third.expectFatal(RelayErrors.rateLimited);
  });
}

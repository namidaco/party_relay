import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  /// a host, a member that stays connected and one that drops before the room changes.
  Future<(CreatedRoom, TestClient, TestClient, TestClient)> partyWithAbsent() async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final present = await relay.join(room.code, name: 'present', did: 'did-present');
    final absent = await relay.join(room.code, name: 'absent', did: 'did-absent');
    await host.expectFrame(Ctrl.joined);
    await host.expectFrame(Ctrl.joined);
    await present.expectFrame(Ctrl.joined);
    await absent.close();
    await host.expectFrame(Ctrl.left);
    await present.expectFrame(Ctrl.left);
    return (room, host, present, absent);
  }

  Future<void> setOpts(TestClient host, TestClient member, Map<String, Object?> opts) async {
    host.send({'t': Ctrl.opts, ...opts});
    await host.expectFrame(Ctrl.opts);
    await member.expectFrame(Ctrl.opts);
  }

  Future<TestClient> rejoinRefused(String code, String? token, String error, {String? password}) async {
    final client = await relay.connect(code);
    client.send({'t': Ctrl.join, 'pv': 1, 'name': 'absent', 'did': 'did-absent', 'token': token, 'password': password});
    await client.expectFatal(error);
    return client;
  }

  test('turning approval on makes absent members ask again', () async {
    final (room, host, present, absent) = await partyWithAbsent();
    await setOpts(host, present, {'approval': true});

    final back = await relay.connect(room.code);
    expect((await back.joinRaw(name: 'absent', did: 'did-absent', token: absent.token))['t'], Ctrl.pending);
    final request = await host.expectFrame(Ctrl.joinreq);
    host.send({'t': Ctrl.approve, 'r': request['r'], 'ok': true});
    back.adopt(await back.expectFrame(Ctrl.welcome));
    expect(back.n, greaterThan(absent.n), reason: 'a revoked token must start a fresh member');
    await host.expectFrame(Ctrl.joined);
    await present.expectFrame(Ctrl.joined);

    // -- connected members were admitted under the new rules already
    await present.close();
    await host.expectFrame(Ctrl.left);
    final resumed = await relay.join(room.code, name: 'present', did: 'did-present', token: present.token);
    expect(resumed.n, present.n);
  });

  test('locking keeps absent members out', () async {
    final (room, host, present, absent) = await partyWithAbsent();
    await setOpts(host, present, {'locked': true});
    await rejoinRefused(room.code, absent.token, RelayErrors.locked);
  });

  test('a new password applies to absent members', () async {
    final (room, host, present, absent) = await partyWithAbsent();
    await setOpts(host, present, {'password': 'one'});
    await rejoinRefused(room.code, absent.token, RelayErrors.badPassword);

    final back = await relay.join(room.code, name: 'absent', did: 'did-absent', token: absent.token, password: 'one');
    expect(back.n, greaterThan(absent.n));
    await host.expectFrame(Ctrl.joined);
    await present.expectFrame(Ctrl.joined);
    await back.close();
    await host.expectFrame(Ctrl.left);
    await present.expectFrame(Ctrl.left);

    // -- changing it is stricter too
    await setOpts(host, present, {'password': 'two'});
    await rejoinRefused(room.code, back.token, RelayErrors.badPassword, password: 'one');
  });

  test('unchanged or looser rules keep absent tokens', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    var member = await relay.join(room.code, name: 'm', did: 'did-m');
    await host.expectFrame(Ctrl.joined);
    const strict = <String, Object?>{'approval': true, 'locked': true, 'password': 'pw'};
    await setOpts(host, member, strict);
    final n = member.n;

    await member.close();
    await host.expectFrame(Ctrl.left);
    host.send({'t': Ctrl.opts, ...strict});
    await host.expectFrame(Ctrl.opts);
    member = await relay.join(room.code, name: 'm', did: 'did-m', token: member.token);
    expect(member.n, n);
    await host.expectFrame(Ctrl.joined);

    await member.close();
    await host.expectFrame(Ctrl.left);
    host.send({'t': Ctrl.opts, 'approval': false, 'locked': false, 'password': null});
    await host.expectFrame(Ctrl.opts);
    member = await relay.join(room.code, name: 'm', did: 'did-m', token: member.token);
    expect(member.n, n);
  });

  test('a resume needs a free slot, the host slot stays reserved', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final members = <TestClient>[];
    for (var i = 1; i < room.max; i++) {
      members.add(await relay.join(room.code, name: 'm$i'));
    }
    final dropped = members.removeAt(0);
    await dropped.close();
    await host.waitFor(Ctrl.left, (f) => f['n'] == dropped.n);
    final taker = await relay.join(room.code, name: 'taker');
    await rejoinRefused(room.code, dropped.token, RelayErrors.full);

    await taker.close();
    await host.waitFor(Ctrl.left, (f) => f['n'] == taker.n);
    await host.close();
    await members.first.waitFor(Ctrl.host, (f) => f['online'] == false);
    await relay.join(room.code, name: 'filler');
    await rejoinRefused(room.code, null, RelayErrors.full);

    final hostBack = await relay.join(room.code, name: 'host', token: room.token);
    expect(hostBack.n, 1);
  });

  test('pending requests follow the host', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final a = await relay.join(room.code, name: 'a', did: 'did-a');
    await host.expectFrame(Ctrl.joined);
    await setOpts(host, a, {'approval': true});

    final guest = await relay.connect(room.code);
    expect((await guest.joinRaw(name: 'waiting', did: 'did-waiting'))['t'], Ctrl.pending);
    final request = await host.expectFrame(Ctrl.joinreq);

    await host.close();
    final hostBack = await relay.join(room.code, name: 'host', token: room.token);
    final again = await hostBack.expectFrame(Ctrl.joinreq);
    expect(again['r'], request['r']);
    expect(again['name'], 'waiting');
    expect(again['did'], 'did-waiting');

    hostBack.send({'t': Ctrl.transfer, 'n': a.n});
    await a.waitFor(Ctrl.host, (f) => f['n'] == a.n);
    expect((await a.expectFrame(Ctrl.joinreq))['r'], request['r']);
    await hostBack.waitFor(Ctrl.host, (f) => f['n'] == a.n);
    await hostBack.expectSilence();

    a.send({'t': Ctrl.approve, 'r': request['r'], 'ok': true});
    expect((await guest.expectFrame(Ctrl.welcome))['n'], greaterThan(a.n));
  });
}

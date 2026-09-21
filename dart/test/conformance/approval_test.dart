import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  Future<(TestClient host, TestClient guest, Map<String, dynamic> request)> pendingRoom(CreatedRoom room) async {
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final guest = await relay.connect(room.code);
    guest.send({'t': Ctrl.join, 'pv': 1, 'name': 'waiting', 'did': 'waiting-did'});
    await guest.expectFrame(Ctrl.pending);
    final request = await host.expectFrame(Ctrl.joinreq);
    expect(request['r'], isA<String>());
    expect(request['name'], 'waiting');
    expect(request['did'], 'waiting-did');
    return (host, guest, request);
  }

  test('approve lets the pending member in', () async {
    final room = await relay.createRoom(approval: true);
    final (host, guest, request) = await pendingRoom(room);
    host.send({'t': Ctrl.approve, 'r': request['r'], 'ok': true});
    final welcome = await guest.expectFrame(Ctrl.welcome);
    guest.adopt(welcome);
    expect(welcome['n'], 2);
    expect(welcome['opts'], {'approval': true, 'password': false, 'locked': false});
    final joined = await host.expectFrame(Ctrl.joined);
    expect(joined['n'], 2);
  });

  test('reject is fatal for the pending member', () async {
    final room = await relay.createRoom(approval: true);
    final (host, guest, request) = await pendingRoom(room);
    host.send({'t': Ctrl.approve, 'r': request['r'], 'ok': false});
    await guest.expectFatal(RelayErrors.rejected);
    await host.expectSilence();
  });

  test('joinreqgone when the pending socket closes', () async {
    final room = await relay.createRoom(approval: true);
    final (host, guest, request) = await pendingRoom(room);
    await guest.close();
    final gone = await host.expectFrame(Ctrl.joinreqgone);
    expect(gone['r'], request['r']);
  });

  test('pending requests time out', () async {
    final room = await relay.createRoom(approval: true);
    final (host, guest, request) = await pendingRoom(room);
    await guest.expectFatal(RelayErrors.timeout, const Duration(milliseconds: kPendingTimeoutMs * 3));
    final gone = await host.expectFrame(Ctrl.joinreqgone);
    expect(gone['r'], request['r']);
  });

  test('host_offline when nobody can approve', () async {
    final room = await relay.createRoom(approval: true);
    final guest = await relay.connect(room.code);
    guest.send({'t': Ctrl.join, 'pv': 1, 'name': 'guest', 'did': 'guest-did'});
    await guest.expectFatal(RelayErrors.hostOffline);
  });

  test('approve is host only', () async {
    final room = await relay.createRoom(approval: true);
    final (host, guest, request) = await pendingRoom(room);
    host.send({'t': Ctrl.approve, 'r': request['r'], 'ok': true});
    await guest.expectFrame(Ctrl.welcome);
    await host.expectFrame(Ctrl.joined);

    guest.send({'t': Ctrl.approve, 'r': 'whatever', 'ok': true});
    await guest.expectError(RelayErrors.forbidden, fatal: false);
  });
}

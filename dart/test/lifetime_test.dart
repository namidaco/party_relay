import 'dart:convert';
import 'dart:io';

import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'conformance/harness.dart';

const PartyRelayConfig _idle = PartyRelayConfig(
  hostGrace: Duration(milliseconds: 200),
  joinTimeout: Duration(milliseconds: 500),
  idleTimeout: Duration(milliseconds: 300),
  maxMembers: 4,
);

const PartyRelayConfig _shortLived = PartyRelayConfig(
  hostGrace: Duration(milliseconds: 200),
  joinTimeout: Duration(milliseconds: 500),
  roomLifetime: Duration(milliseconds: 600),
  maxMembers: 4,
);

const PartyRelayConfig _pinged = PartyRelayConfig(
  pingInterval: Duration(milliseconds: 100),
  maxMembers: 4,
);

const PartyRelayConfig _fewRetained = PartyRelayConfig(
  maxMembers: 4,
  maxRetainedMembers: 2,
);

void main() {
  test('stopping the server closes its rooms for everyone', () async {
    final relay = await RelayTarget.start(config: _idle, local: true);
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final guest = await relay.join(room.code, name: 'guest');
    await host.expectFrame(Ctrl.joined);
    await relay.server!.close();
    for (final client in [host, guest]) {
      expect((await client.expectFrame(Ctrl.closed))['r'], ClosedReason.shutdown);
      await client.done;
    }
    await relay.dispose();
  });

  test('a room nobody joins goes idle', () async {
    final relay = await RelayTarget.start(config: _idle, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    expect(relay.server!.hasRoom(room.code), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(relay.server!.hasRoom(room.code), isFalse);
    expect((await relay.upgrade(room.code) as HttpResult).status, 404);
  });

  test('a room goes idle after the last member leaves', () async {
    final relay = await RelayTarget.start(config: _idle, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(relay.server!.hasRoom(room.code), isTrue, reason: 'a connected member keeps the room');
    await host.close();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(relay.server!.hasRoom(room.code), isFalse);
  });

  test('a room expires while members are connected', () async {
    final relay = await RelayTarget.start(config: _shortLived, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final frame = await host.expectFrame(Ctrl.closed, const Duration(seconds: 5));
    expect(frame['r'], ClosedReason.expired);
    await host.done;
    expect(relay.server!.hasRoom(room.code), isFalse);
  });

  test('a member that stops answering pings is dropped', () async {
    final relay = await RelayTarget.start(config: _pinged, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final silent = await _joinSilently(relay, room.code);
    addTearDown(silent.destroy);
    final joined = await host.expectFrame(Ctrl.joined);
    final left = await host.expectFrame(Ctrl.left, const Duration(seconds: 2));
    expect(left['n'], joined['n']);
    expect(left['r'], LeftReason.lost);
    await host.expectSilence(const Duration(milliseconds: 400));
    expect(host.isOpen, isTrue, reason: 'a client answering pings stays');
  });

  test('a joiner past the retained members cap keeps its record', () async {
    final relay = await RelayTarget.start(config: _fewRetained, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    await relay.join(room.code, name: 'a');
    final b = await relay.join(room.code, name: 'b');
    host.sendData(DataRoute.member, b.n, const [1, 2]);
    expectDataFrame(await b.nextData(const Duration(seconds: 2)), DataRoute.member, host.n, const [1, 2]);
  });
}

/// joins over a raw socket that never reads, like a phone that vanished without closing.
Future<Socket> _joinSilently(RelayTarget relay, String code) async {
  final client = HttpClient();
  final req = await client.openUrl('GET', relay.base.replace(path: '/v1/room/$code'));
  req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
  req.headers.set(HttpHeaders.upgradeHeader, 'websocket');
  req.headers.set('Sec-WebSocket-Version', '13');
  req.headers.set('Sec-WebSocket-Key', base64.encode(List<int>.filled(16, 7)));
  final res = await req.close();
  final socket = await res.detachSocket();
  client.close();
  final payload = utf8.encode(jsonEncode({'t': Ctrl.join, 'pv': 1, 'name': 'silent', 'did': 'did-silent'}));
  // -- a masked client text frame, the zero mask leaves the payload as is
  socket.add([0x81, 0x80 | payload.length, 0, 0, 0, 0, ...payload]);
  return socket;
}

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

void main() {
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
}

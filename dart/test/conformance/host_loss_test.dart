import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

const Duration kAfterGrace = Duration(milliseconds: kHostGraceMs * 3);

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

  Future<void> expectHostLost(TestClient client, int hostN) async {
    final left = await client.expectFrame(Ctrl.left);
    expect(left['n'], hostN);
    expect(left['r'], LeftReason.lost);
    final host = await client.expectFrame(Ctrl.host);
    expect(host['n'], hostN);
    expect(host['online'], false);
  }

  test('successors decide the promotion', () async {
    final (_, host, a, b) = await party();
    final preferred = <int>[b.n];
    host.send({'t': Ctrl.successors, 'ns': preferred});
    await host.close();
    await expectHostLost(a, 1);
    await expectHostLost(b, 1);

    for (final client in [a, b]) {
      final frame = await client.expectFrame(Ctrl.host, kAfterGrace);
      expect(frame['n'], b.n);
      expect(frame['online'], true);
    }
    b.send({'t': Ctrl.opts, 'locked': true});
    expect((await b.expectFrame(Ctrl.opts))['locked'], true);
  });

  test('without successors the lowest n is promoted', () async {
    final (_, host, a, b) = await party();
    await host.close();
    await expectHostLost(a, 1);
    await expectHostLost(b, 1);
    for (final client in [a, b]) {
      expect((await client.expectFrame(Ctrl.host, kAfterGrace))['n'], a.n);
    }
  });

  test('the old host comes back as a normal member', () async {
    final (room, host, a, b) = await party();
    await host.close();
    await expectHostLost(a, 1);
    await expectHostLost(b, 1);
    expect((await a.expectFrame(Ctrl.host, kAfterGrace))['n'], a.n);
    await b.expectFrame(Ctrl.host, kAfterGrace);

    final back = await relay.join(room.code, name: 'host', token: room.token);
    expect(back.n, 1);
    expect(back.welcome!['host'], a.n);
    expect(back.welcome!['hostOnline'], true);
    expect((await a.expectFrame(Ctrl.joined))['n'], 1);

    back.send({'t': Ctrl.close});
    await back.expectError(RelayErrors.forbidden, fatal: false);
  });

  test('a hostless room hands the room to the first joiner', () async {
    final room = await relay.createRoom();
    await Future<void>.delayed(const Duration(milliseconds: kHostGraceMs + 500));
    final first = await relay.join(room.code, name: 'first', did: 'did-first');
    expect(first.welcome!['host'], first.n);
    expect(first.welcome!['hostOnline'], true);
    first.send({'t': Ctrl.opts, 'approval': true});
    expect((await first.expectFrame(Ctrl.opts))['approval'], true);
  });

  test('the host can resume within the grace window', () async {
    final (room, host, a, _) = await party();
    await host.close();
    await expectHostLost(a, 1);
    final back = await relay.join(room.code, name: 'host', token: room.token);
    expect(back.n, 1);
    expect(back.welcome!['host'], 1);
    expect((await a.expectFrame(Ctrl.joined))['n'], 1);
    expect((await a.expectFrame(Ctrl.host))['online'], true);
    await a.expectSilence(const Duration(milliseconds: kHostGraceMs + 400));
  });
}

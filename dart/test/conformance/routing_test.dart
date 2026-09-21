import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  Future<(TestClient, TestClient, TestClient)> party() async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final a = await relay.join(room.code, name: 'a');
    final b = await relay.join(room.code, name: 'b');
    await host.expectFrame(Ctrl.joined);
    await host.expectFrame(Ctrl.joined);
    await a.expectFrame(Ctrl.joined);
    expect(host.n, 1);
    expect(a.n, 2);
    expect(b.n, 3);
    return (host, a, b);
  }

  test('route 0 reaches the host with the sender n', () async {
    final (host, a, b) = await party();
    final payload = pattern(1024);
    a.sendData(DataRoute.host, 0, payload);
    expectDataFrame(await host.nextData(), DataRoute.host, a.n, payload);
    await b.expectSilence();
  });

  test('route 0 with an empty payload', () async {
    final (host, a, _) = await party();
    a.sendData(DataRoute.host, 999, const []);
    expectDataFrame(await host.nextData(), DataRoute.host, a.n, const []);
  });

  test('route 1 broadcasts to everyone but the host and the skipped member', () async {
    final (host, a, b) = await party();
    final payload = pattern(2048);
    host.sendData(DataRoute.broadcast, 0, payload);
    expectDataFrame(await a.nextData(), DataRoute.broadcast, host.n, payload);
    expectDataFrame(await b.nextData(), DataRoute.broadcast, host.n, payload);
    await host.expectSilence();

    final second = pattern(64);
    host.sendData(DataRoute.broadcast, b.n, second);
    expectDataFrame(await a.nextData(), DataRoute.broadcast, host.n, second);
    await b.expectSilence();
  });

  test('route 2 reaches a single member', () async {
    final (host, a, b) = await party();
    final payload = pattern(300);
    host.sendData(DataRoute.member, b.n, payload);
    expectDataFrame(await b.nextData(), DataRoute.member, host.n, payload);
    await a.expectSilence();
  });

  test('a big host frame survives byte for byte', () async {
    final (host, a, _) = await party();
    final payload = pattern(900 * 1024);
    host.sendData(DataRoute.broadcast, 0, payload);
    expectDataFrame(await a.nextData(), DataRoute.broadcast, host.n, payload);
  });

  test('non hosts can not use route 1 or 2', () async {
    final (host, a, b) = await party();
    a.sendData(DataRoute.broadcast, 0, pattern(8));
    await a.expectError(RelayErrors.forbidden, fatal: false);
    a.sendData(DataRoute.member, b.n, pattern(8));
    await a.expectError(RelayErrors.forbidden, fatal: false);
    await b.expectSilence();
    await host.expectSilence();
  });

  test('route 0 from the host is dropped', () async {
    final (host, a, b) = await party();
    host.sendData(DataRoute.host, 0, pattern(8));
    await host.expectSilence();
    await a.expectSilence();
    await b.expectSilence();
  });

  test('route 0 while the host is offline is dropped', () async {
    final (host, a, b) = await party();
    await host.close();
    expect((await a.expectFrame(Ctrl.left))['r'], LeftReason.lost);
    expect((await a.expectFrame(Ctrl.host))['online'], false);
    await b.expectFrame(Ctrl.left);
    await b.expectFrame(Ctrl.host);

    a.sendData(DataRoute.host, 0, pattern(8));
    await b.expectSilence();
    a.send({'t': Ctrl.ping, 'c': 1});
    await a.expectFrame(Ctrl.pong);
  });

  test('unknown routes are rejected', () async {
    final (host, a, b) = await party();
    a.sendData(9, 0, pattern(4));
    await a.expectError(RelayErrors.badRequest, fatal: false);
    a.sendRaw(const [1, 2]);
    await a.expectError(RelayErrors.badRequest, fatal: false);
    await host.expectSilence();
    await b.expectSilence();
  });
}

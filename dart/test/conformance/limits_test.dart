import 'dart:convert';

import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

const int kGuestFrameMax = 16 * 1024;
const int kHostFrameMax = 1024 * 1024;
const int kTextFrameMax = 2 * 1024;

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  Future<(TestClient, TestClient)> pair() async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final guest = await relay.join(room.code, name: 'guest');
    await host.expectFrame(Ctrl.joined);
    return (host, guest);
  }

  test('a guest frame at the limit goes through', () async {
    final (host, guest) = await pair();
    final payload = pattern(kGuestFrameMax - kDataHeaderSize);
    guest.sendData(DataRoute.host, 0, payload);
    expectDataFrame(await host.nextData(), DataRoute.host, guest.n, payload);
  });

  test('a guest frame over the limit is dropped, socket survives', () async {
    final (host, guest) = await pair();
    guest.sendData(DataRoute.host, 0, pattern(kGuestFrameMax - kDataHeaderSize + 1));
    await guest.expectError(RelayErrors.tooLarge, fatal: false);
    await host.expectSilence();
    guest.send({'t': Ctrl.ping, 'c': 9});
    expect((await guest.expectFrame(Ctrl.pong))['c'], 9);
  });

  test('a host frame over the limit is dropped', () async {
    final (host, guest) = await pair();
    host.sendData(DataRoute.broadcast, 0, pattern(kHostFrameMax - kDataHeaderSize + 1));
    await host.expectError(RelayErrors.tooLarge, fatal: false);
    await guest.expectSilence();
  });

  test('text frames over the limit are dropped', () async {
    final (host, guest) = await pair();
    guest.sendText(jsonEncode({'t': Ctrl.ping, 'c': 1, 'pad': 'x' * kTextFrameMax}));
    await guest.expectError(RelayErrors.tooLarge, fatal: false);
    guest.send({'t': Ctrl.ping, 'c': 3});
    expect((await guest.expectFrame(Ctrl.pong))['c'], 3);
    await host.expectSilence();
  });

  test(
    'sustained abuse gets a warning then a fatal close',
    () async {
      final (host, guest) = await pair();
      for (var i = 0; i < kRateDropClose + 120; i++) {
        guest.sendData(DataRoute.host, 0, const [7]);
      }
      await guest.expectError(RelayErrors.rateLimited, fatal: false);
      await guest.done.timeout(const Duration(seconds: 20));

      var fatal = false;
      while (guest.queued > 0) {
        final frame = await guest.nextText();
        if (frame['t'] == Ctrl.error && frame['code'] == RelayErrors.rateLimited && frame['fatal'] == true) fatal = true;
      }
      expect(fatal, isTrue, reason: 'expected a fatal rate_limited before the close');
      expect(host.isOpen, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

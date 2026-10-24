import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'conformance/harness.dart';

/// a small cap so the oversized messages stay cheap. a long join timeout, so a socket that closes did not time out.
final PartyRelayConfig _guarded = conformanceConfig().copyWith(maxHostFrameBytes: 64 * 1024, joinTimeout: const Duration(seconds: 30));

const Duration _dropTimeout = Duration(seconds: 2);

void main() {
  late RelayTarget relay;

  setUp(() async => relay = await RelayTarget.start(config: _guarded, local: true));
  tearDown(() async => relay.dispose());

  test('the handshake answers the rfc 6455 accept and negotiates no extension', () async {
    final room = await relay.createRoom();
    final res = await _upgradeRequest(relay, room.code, 'dGhlIHNhbXBsZSBub25jZQ==', extensions: 'permessage-deflate; client_max_window_bits');
    expect(res.statusCode, HttpStatus.switchingProtocols);
    expect(res.headers.value('sec-websocket-accept'), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
    expect(res.headers.value('sec-websocket-extensions'), isNull);
    final socket = await res.detachSocket();
    socket.destroy();
  });

  test('a dart:io client accepts the handshake and sees the relay close code', () async {
    final room = await relay.createRoom();
    final ws = await WebSocket.connect('ws://127.0.0.1:${relay.server!.port}/v1/room/${room.code}');
    ws.add('not json');
    final frames = await ws.toList().timeout(_dropTimeout);
    final error = jsonDecode(frames.single as String) as Map<String, dynamic>;
    expect(error['code'], RelayErrors.badRequest);
    expect(error['fatal'], true);
    expect(ws.closeCode, kRelayCloseCode);
  });

  test('a message at the cap reaches the relay, one byte more drops the connection', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final guest = await relay.join(room.code, name: 'guest');
    await host.expectFrame(Ctrl.joined);

    guest.sendRaw(pattern(_guarded.maxMessageBytes));
    await guest.expectError(RelayErrors.tooLarge, fatal: false);
    await guest.roundTrip();

    guest.sendRaw(pattern(_guarded.maxMessageBytes + 1));
    final left = await host.expectFrame(Ctrl.left, _dropTimeout);
    expect(left['n'], guest.n);
    expect(left['r'], LeftReason.lost);
    await guest.done.timeout(_dropTimeout);
    expect(guest.queued, 0, reason: 'dropped without an error frame');
  });

  test('a socket that has not joined is dropped as soon as a header claims too much', () async {
    final room = await relay.createRoom();
    final raw = await _RawClient.connect(relay, room.code);
    raw.sendHeader(_Opcode.binary, 1 << 32);
    raw.socket.add(pattern(1024));
    await raw.closed.timeout(_dropTimeout);
    expect(raw.receivedBytes, 0, reason: 'no join timeout, no error frame');
  });

  test('fragments count together', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    final raw = await _RawClient.connect(relay, room.code);
    raw.sendFrame(_Opcode.text, utf8.encode(jsonEncode({'t': Ctrl.join, 'pv': 1, 'name': 'raw', 'did': 'did-raw'})));
    final joined = await host.expectFrame(Ctrl.joined);

    final half = _guarded.maxMessageBytes ~/ 2 + 1;
    raw.sendFrame(_Opcode.binary, pattern(half), fin: false);
    raw.sendHeader(_Opcode.continuation, half);
    final left = await host.expectFrame(Ctrl.left, _dropTimeout);
    expect(left['n'], joined['n']);
    expect(left['r'], LeftReason.lost);
    await raw.closed.timeout(_dropTimeout);
  });
}

Future<HttpClientResponse> _upgradeRequest(RelayTarget relay, String code, String key, {String? extensions}) async {
  final client = HttpClient();
  final req = await client.openUrl('GET', relay.base.replace(path: '/v1/room/$code'));
  req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
  req.headers.set(HttpHeaders.upgradeHeader, 'websocket');
  req.headers.set('Sec-WebSocket-Version', '13');
  req.headers.set('Sec-WebSocket-Key', key);
  if (extensions != null) req.headers.set('Sec-WebSocket-Extensions', extensions);
  final res = await req.close();
  client.close();
  return res;
}

/// a websocket client written by hand, so a header can claim any length.
class _RawClient {
  _RawClient._(this.socket) {
    socket.listen((chunk) => receivedBytes += chunk.length, onError: (Object _) => _finish(), onDone: _finish, cancelOnError: true);
  }

  static Future<_RawClient> connect(RelayTarget relay, String code) async {
    final res = await _upgradeRequest(relay, code, base64.encode(List<int>.filled(16, 7)));
    expect(res.statusCode, HttpStatus.switchingProtocols);
    final socket = await res.detachSocket();
    return _RawClient._(socket);
  }

  final Socket socket;
  final Completer<void> _closed = Completer<void>();
  int receivedBytes = 0;

  Future<void> get closed => _closed.future;

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
  }

  /// masked with a zero key, so the payload goes out as is.
  void sendHeader(int opcode, int length, {bool fin = true}) {
    final header = BytesBuilder();
    final finBit = fin ? 0x80 : 0;
    header.addByte(finBit | opcode);
    if (length < 126) {
      header.addByte(0x80 | length);
    } else if (length < 0x10000) {
      header.addByte(0x80 | 126);
      header.add([length >> 8, length & 0xFF]);
    } else {
      header.addByte(0x80 | 127);
      header.add([for (var shift = 56; shift >= 0; shift -= 8) (length >> shift) & 0xFF]);
    }
    header.add(const [0, 0, 0, 0]);
    socket.add(header.takeBytes());
  }

  void sendFrame(int opcode, List<int> payload, {bool fin = true}) {
    sendHeader(opcode, payload.length, fin: fin);
    socket.add(payload);
  }
}

abstract final class _Opcode {
  static const int continuation = 0x0;
  static const int text = 0x1;
  static const int binary = 0x2;
}

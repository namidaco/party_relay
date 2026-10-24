// by claude

part of 'server.dart';

/// the upgrade [WebSocketTransformer.upgrade] does, but over a [_GuardedSocket] so an oversized message is never
/// buffered.
abstract final class _WebSocketHandshake {
  static const String _kGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  static const List<int> _kSha1Initial = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];

  /// [req] passed [WebSocketTransformer.isUpgradeRequest]. no extension is negotiated, a compressed frame could inflate
  /// past [maxMessageBytes].
  static Future<WebSocket> upgrade(HttpRequest req, int maxMessageBytes) async {
    final key = req.headers.value('Sec-WebSocket-Key') ?? '';
    final accept = _acceptOf(key);
    final res = req.response;
    res.statusCode = HttpStatus.switchingProtocols;
    res.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    res.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    res.headers.set('Sec-WebSocket-Accept', accept);
    res.headers.contentLength = 0;
    final socket = await res.detachSocket();
    final guarded = _GuardedSocket(socket, maxMessageBytes);
    return WebSocket.fromUpgradedSocket(guarded, serverSide: true, compression: CompressionOptions.compressionOff);
  }

  static String _acceptOf(String key) {
    final keyBytes = utf8.encode('$key$_kGuid');
    final digest = _sha1(keyBytes);
    return base64.encode(digest);
  }

  /// fips 180-4 sha-1, only ever used for `Sec-WebSocket-Accept`.
  static Uint8List _sha1(List<int> data) {
    final length = data.length;
    final padded = Uint8List(((length + 9 + 63) >> 6) << 6);
    padded.setRange(0, length, data);
    padded[length] = 0x80;
    final bits = length * 8;
    final view = ByteData.view(padded.buffer);
    view.setUint32(padded.length - 8, (bits >>> 32) & 0xFFFFFFFF);
    view.setUint32(padded.length - 4, bits & 0xFFFFFFFF);

    final h = Uint32List.fromList(_kSha1Initial);
    final w = Uint32List(80);
    for (var offset = 0; offset < padded.length; offset += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = view.getUint32(offset + (i << 2));
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
      for (var i = 0; i < 80; i++) {
        final int f;
        final int k;
        if (i < 20) {
          f = (b & c) | (~b & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }
        final t = (_rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
        e = d;
        d = c;
        c = _rotl(b, 30);
        b = a;
        a = t;
      }
      h[0] += a;
      h[1] += b;
      h[2] += c;
      h[3] += d;
      h[4] += e;
    }

    final digest = Uint8List(20);
    final digestView = ByteData.view(digest.buffer);
    for (var i = 0; i < 5; i++) {
      digestView.setUint32(i << 2, h[i]);
    }
    return digest;
  }

  static int _rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;
}

/// the upgraded connection as [WebSocket] sees it. reads pass through a [_FrameSizeGuard], everything else is the
/// socket.
class _GuardedSocket extends Stream<Uint8List> implements Socket {
  _GuardedSocket(Socket socket, int maxMessageBytes)
      : _socket = socket,
        _incoming = Stream<Uint8List>.eventTransformed(socket, (out) => _FrameSizeGuard(out, socket, maxMessageBytes));

  final Socket _socket;
  final Stream<Uint8List> _incoming;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _incoming.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _socket.writeAll(objects, separator);

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}

/// follows the rfc 6455 frame headers as the bytes go by, the chunks themselves are passed on untouched. a message (the
/// sum of its fragments) over [_maxMessageBytes], or a control frame over the rfc limit, destroys the socket as soon as
/// its header is read.
class _FrameSizeGuard implements EventSink<Uint8List> {
  _FrameSizeGuard(this._out, this._socket, this._maxMessageBytes);

  static const int _kMaxControlBytes = 125;
  static const int _kMaskBytes = 4;

  final EventSink<Uint8List> _out;
  final Socket _socket;
  final int _maxMessageBytes;

  _FrameStep _step = _FrameStep.opcode;
  bool _isControl = false;
  bool _isContinuation = false;
  bool _isMasked = false;
  int _headerBytesLeft = 0;
  int _frameBytes = 0;
  int _messageBytes = 0;
  int _payloadBytesLeft = 0;
  bool _isKilled = false;

  @override
  void add(Uint8List chunk) {
    if (_isKilled) return;
    final end = chunk.length;
    var i = 0;
    while (i < end) {
      final payloadBytesLeft = _payloadBytesLeft;
      if (payloadBytesLeft > 0) {
        final available = end - i;
        final skipped = available < payloadBytesLeft ? available : payloadBytesLeft;
        _payloadBytesLeft = payloadBytesLeft - skipped;
        i += skipped;
        continue;
      }
      final isAllowed = _readHeaderByte(chunk[i]);
      if (!isAllowed) return _kill();
      i++;
    }
    _out.add(chunk);
  }

  /// false when the frame must not be let through.
  bool _readHeaderByte(int byte) {
    switch (_step) {
      case _FrameStep.opcode:
        final opcode = byte & 0x0F;
        _isControl = opcode >= 0x8;
        _isContinuation = opcode == 0x0;
        _step = _FrameStep.length;
        return true;
      case _FrameStep.length:
        _isMasked = (byte & 0x80) != 0;
        final length = byte & 0x7F;
        if (length < 126) {
          _frameBytes = length;
          return _onLengthRead();
        }
        _frameBytes = 0;
        _headerBytesLeft = length == 126 ? 2 : 8;
        _step = _FrameStep.extendedLength;
        return true;
      case _FrameStep.extendedLength:
        _frameBytes = (_frameBytes << 8) | byte;
        // -- checked per byte, so a 64 bit length never overflows
        if (_frameBytes > _maxMessageBytes) return false;
        _headerBytesLeft--;
        if (_headerBytesLeft > 0) return true;
        return _onLengthRead();
      case _FrameStep.mask:
        _headerBytesLeft--;
        if (_headerBytesLeft == 0) _startPayload();
        return true;
    }
  }

  bool _onLengthRead() {
    if (_isControl) {
      if (_frameBytes > _kMaxControlBytes) return false;
    } else {
      final messageBytes = _isContinuation ? _messageBytes + _frameBytes : _frameBytes;
      if (messageBytes > _maxMessageBytes) return false;
      _messageBytes = messageBytes;
    }
    if (_isMasked) {
      _headerBytesLeft = _kMaskBytes;
      _step = _FrameStep.mask;
    } else {
      _startPayload();
    }
    return true;
  }

  void _startPayload() {
    _payloadBytesLeft = _frameBytes;
    _step = _FrameStep.opcode;
  }

  void _kill() {
    _isKilled = true;
    _socket.destroy();
    _out.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_isKilled) return;
    _out.addError(error, stackTrace);
  }

  @override
  void close() {
    if (_isKilled) return;
    _out.close();
  }
}

enum _FrameStep {
  opcode,
  length,
  extendedLength,
  mask,
  ;
}

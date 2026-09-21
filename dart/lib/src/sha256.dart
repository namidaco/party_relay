import 'dart:typed_data';

const List<int> _initial = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const String _hexDigits = '0123456789abcdef';

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// fips 180-4 sha-256. the package carries its own so it stays dependency free.
Uint8List sha256(List<int> data) {
  final length = data.length;
  final padded = Uint8List(((length + 9 + 63) >> 6) << 6);
  padded.setRange(0, length, data);
  padded[length] = 0x80;
  final bits = length * 8;
  final view = ByteData.view(padded.buffer);
  view.setUint32(padded.length - 8, (bits >>> 32) & 0xFFFFFFFF);
  view.setUint32(padded.length - 4, bits & 0xFFFFFFFF);

  final h = Uint32List.fromList(_initial);
  final w = Uint32List(64);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + (i << 2));
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], acc = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = (acc + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      acc = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += acc;
  }

  final digest = Uint8List(32);
  final digestView = ByteData.view(digest.buffer);
  for (var i = 0; i < 8; i++) {
    digestView.setUint32(i << 2, h[i]);
  }
  return digest;
}

/// lower case hex of the first [bytes] digest bytes.
String sha256Hex(List<int> data, [int bytes = 32]) {
  final digest = sha256(data);
  final count = bytes < 32 ? bytes : 32;
  final out = StringBuffer();
  for (var i = 0; i < count; i++) {
    out.writeCharCode(_hexDigits.codeUnitAt(digest[i] >> 4));
    out.writeCharCode(_hexDigits.codeUnitAt(digest[i] & 0xF));
  }
  return out.toString();
}

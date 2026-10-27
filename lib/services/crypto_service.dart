import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../constants/api_endpoints.dart';

class CryptoService {
  static final AesGcm _algorithm = AesGcm.with256bits();

  /// Converts a Hex string to Uint8List bytes
  static Uint8List hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '');
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      final num = int.parse(hex.substring(i, i + 2), radix: 16);
      result[i ~/ 2] = num;
    }
    return result;
  }

  /// Decrypts a sensitive config token (AES-256-GCM Base64) in RAM.
  /// Structure: 12-byte Nonce + Ciphertext + 16-byte AuthTag
  static Future<Map<String, dynamic>?> decryptTemplateConfig(String token) async {
    if (token.isEmpty) return null;
    try {
      final raw = base64.decode(token);
      if (raw.length < 28) return null;

      final secretKey = SecretKey(hexToBytes(ApiEndpoints.masterSecretKey));
      final secretBox = SecretBox.fromConcatenation(
        raw,
        nonceLength: 12,
        macLength: 16,
      );

      final decryptedBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      final jsonStr = utf8.decode(decryptedBytes);
      return json.decode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Decrypts a full armored blob returned by the API (?armored=1)
  static Future<Map<String, dynamic>?> decryptArmoredBlob(String blobBase64) async {
    return await decryptTemplateConfig(blobBase64);
  }
}

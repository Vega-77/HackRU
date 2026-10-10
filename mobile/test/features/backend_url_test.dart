import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/settings/backend_url.dart';

void main() {
  group('validateBackendUrl', () {
    test('accepts ws and wss addresses', () {
      expect(validateBackendUrl('ws://192.168.1.20:8000/ws/frames'), isNull);
      expect(validateBackendUrl('wss://physics.example.com/ws/frames'), isNull);
      expect(validateBackendUrl('  ws://localhost:8000/ws/frames  '), isNull);
    });

    test('asks for an address when empty', () {
      expect(validateBackendUrl(''), 'Enter the backend address');
      expect(validateBackendUrl('   '), 'Enter the backend address');
    });

    test('explains a missing scheme with an example', () {
      expect(validateBackendUrl('192.168.1.20:8000'), startsWith('Start with'));
    });

    test('names the wrong scheme', () {
      expect(
        validateBackendUrl('http://192.168.1.20:8000/ws/frames'),
        'Use ws:// or wss://, not http://',
      );
    });

    test('asks for a host when there is none', () {
      expect(validateBackendUrl('ws://'), contains('address after ws://'));
    });
  });
}

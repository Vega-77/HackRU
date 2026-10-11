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

    test('explains that an https page cannot reach a laptop', () {
      final pages = Uri.parse('https://vega-77.github.io/HackRU/');
      expect(
        validateBackendUrl('ws://192.168.1.20:8000/ws/frames', page: pages),
        contains('--tunnel'),
      );
      expect(
        validateBackendUrl('wss://physics.onrender.com/ws/frames', page: pages),
        isNull,
      );
      expect(
        validateBackendUrl('ws://localhost:8000/ws/frames', page: pages),
        isNull,
        reason: 'browsers allow ws:// to the same computer',
      );
      expect(
        validateBackendUrl(
          'ws://192.168.1.20:8000/ws/frames',
          page: Uri.parse('http://localhost:8080/'),
        ),
        isNull,
      );
    });
  });

  group('normalizeBackendUrl', () {
    test('turns a bare laptop address into a full one', () {
      expect(
        normalizeBackendUrl('192.168.1.20'),
        'ws://192.168.1.20:8000/ws/frames',
      );
      expect(
        normalizeBackendUrl(' 192.168.1.20:9000 '),
        'ws://192.168.1.20:9000/ws/frames',
      );
      expect(
        normalizeBackendUrl('192.168.1.20:8000/ws/frames'),
        'ws://192.168.1.20:8000/ws/frames',
      );
      expect(normalizeBackendUrl('localhost'), 'ws://localhost:8000/ws/frames');
    });

    test('adds the path to a full address without one', () {
      expect(
        normalizeBackendUrl('ws://192.168.1.20:8000'),
        'ws://192.168.1.20:8000/ws/frames',
      );
      expect(
        normalizeBackendUrl('wss://physics.onrender.com/'),
        'wss://physics.onrender.com/ws/frames',
        reason: 'a hosted address keeps its default port',
      );
    });

    test('turns a bare tunnel address into a wss one', () {
      expect(
        normalizeBackendUrl('name-of-tunnel.trycloudflare.com'),
        'wss://name-of-tunnel.trycloudflare.com/ws/frames',
      );
      expect(
        normalizeBackendUrl('laptop.local'),
        'ws://laptop.local:8000/ws/frames',
        reason: 'a .local name is a laptop on the same Wi-Fi',
      );
    });

    test('turns a web address into a WebSocket one', () {
      expect(
        normalizeBackendUrl('https://name-of-tunnel.trycloudflare.com'),
        'wss://name-of-tunnel.trycloudflare.com/ws/frames',
      );
      expect(
        normalizeBackendUrl('http://192.168.1.20:8000'),
        'ws://192.168.1.20:8000/ws/frames',
      );
    });

    test('leaves a complete address alone', () {
      for (final url in [
        'ws://10.0.0.5:8000/ws',
        'wss://handson-physics-backend.onrender.com/ws/frames',
      ]) {
        expect(normalizeBackendUrl(url), url);
      }
    });

    test('leaves what it cannot fix for the validator to explain', () {
      expect(normalizeBackendUrl(''), '');
      expect(normalizeBackendUrl('  '), '');
      expect(
        normalizeBackendUrl('ftp://192.168.1.20:8000'),
        'ftp://192.168.1.20:8000',
      );
      expect(normalizeBackendUrl('ws://'), 'ws://');
    });
  });

  test('treats wss addresses as hosted and ws as local', () {
    expect(isHostedBackend('wss://physics.onrender.com/ws/frames'), isTrue);
    expect(isHostedBackend(' wss://physics.onrender.com/ws/frames '), isTrue);
    expect(isHostedBackend('ws://192.168.1.20:8000/ws/frames'), isFalse);
    expect(isHostedBackend('not a url'), isFalse);
  });

  group('testBackend', () {
    test('tries a local backend once, briefly', () async {
      final timeouts = <Duration>[];
      Future<Duration> probe(String url, Duration timeout) async {
        timeouts.add(timeout);
        throw Exception('refused');
      }

      await expectLater(
        testBackend('ws://192.168.1.20:8000/ws/frames', probe: probe),
        throwsException,
      );
      expect(timeouts, [const Duration(seconds: 3)]);
    });

    test('keeps trying a hosted backend while it wakes up', () async {
      var attempts = 0;
      Future<Duration> probe(String url, Duration timeout) async {
        if (++attempts < 3) throw Exception('503 while waking');
        return const Duration(milliseconds: 40);
      }

      await testBackend(
        'wss://physics.onrender.com/ws/frames',
        retryDelay: Duration.zero,
        probe: probe,
      );
      expect(attempts, 3);
    });

    test('gives up on a hosted backend after the wake timeout', () async {
      var attempts = 0;
      Future<Duration> probe(String url, Duration timeout) async {
        attempts++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw Exception('down');
      }

      await expectLater(
        testBackend(
          'wss://physics.onrender.com/ws/frames',
          wakeTimeout: const Duration(milliseconds: 100),
          retryDelay: const Duration(milliseconds: 10),
          probe: probe,
        ),
        throwsException,
      );
      expect(attempts, inInclusiveRange(2, 5));
    });
  });
}

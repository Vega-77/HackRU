import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/server_error_text.dart';
import 'package:hands_on_physics/models/physics_state.dart';

void main() {
  test('a plain error reads as one sentence', () {
    expect(
      describeServerError(const ErrorMessage('could not decode image bytes')),
      'The backend reported: could not decode image bytes.',
    );
  });

  test('a crash says where, how often and which backend', () {
    const error = ErrorMessage(
      'could not process frame: ValueError: shapes (41,41) (48,48)',
      where: 'backend/cv_engine/universal.py:69 in detect',
      serverVersion: '209bcec',
    );
    expect(
      describeServerError(error, count: 37),
      'The backend reported: could not process frame: ValueError: shapes '
      '(41,41) (48,48). In backend/cv_engine/universal.py:69 in detect. '
      'Same error on 37 frames in a row. Backend version 209bcec.',
    );
  });
}

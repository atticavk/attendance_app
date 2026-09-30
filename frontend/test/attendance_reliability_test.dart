import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('attendance optimizer bounds dimensions and produces JPEG', () {
    final source = img.Image(width: 1600, height: 1200);
    img.fill(source, color: img.ColorRgb8(120, 80, 40));
    final original = Uint8List.fromList(img.encodePng(source));

    final optimized = AttendancePhotoOptimizer.optimize(
      AttendanceUploadPhoto(bytes: original, filename: 'capture.png'),
    );
    final decoded = img.decodeImage(optimized.bytes);

    expect(decoded, isNotNull);
    expect(decoded!.width, 640);
    expect(decoded.height, 480);
    expect(optimized.filename, 'capture.jpg');
    expect(optimized.bytes.length, lessThan(250000));
  });

  test('pending attendance preserves the retry payload', () async {
    SharedPreferences.setMockInitialValues({});
    final pending = PendingAttendanceSubmission(
      type: 'check_in',
      submissionId: '123e4567-e89b-42d3-a456-426614174000',
      latitude: 12.34,
      longitude: 56.78,
      photo: AttendanceUploadPhoto(
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'attendance.jpg',
      ),
      useLoggedInBranchOnly: false,
      createdAt: DateTime.now().toUtc(),
    );

    await PendingAttendanceService.save(pending);
    final restored = await PendingAttendanceService.read();

    expect(restored, isNotNull);
    expect(restored!.submissionId, pending.submissionId);
    expect(restored.photo.bytes, pending.photo.bytes);
    expect(restored.latitude, pending.latitude);
  });

  test('attendance success requires the exact persisted server record', () {
    final submitted = _attendanceRecord(id: 42);

    expect(
      AttendanceSubmissionVerifier.isPersisted(
        attendance: submitted,
        employeeId: 'EMP001',
        isCheckOut: false,
        expectedRecordId: 42,
      ),
      isTrue,
    );
    expect(
      AttendanceSubmissionVerifier.isPersisted(
        attendance: _attendanceRecord(id: 41),
        employeeId: 'EMP001',
        isCheckOut: false,
        expectedRecordId: 42,
      ),
      isFalse,
    );
    expect(
      AttendanceSubmissionVerifier.isPersisted(
        attendance: submitted,
        employeeId: 'OTHER',
        isCheckOut: false,
        expectedRecordId: 42,
      ),
      isFalse,
    );
  });

  test('check-out success requires persisted check-out fields', () {
    expect(
      AttendanceSubmissionVerifier.isPersisted(
        attendance: _attendanceRecord(id: 42),
        employeeId: 'EMP001',
        isCheckOut: true,
        expectedRecordId: 42,
      ),
      isFalse,
    );
    expect(
      AttendanceSubmissionVerifier.isPersisted(
        attendance: _attendanceRecord(
          id: 42,
          checkOutDate: '2026-09-03',
          checkOutTime: '19:00:00',
        ),
        employeeId: 'EMP001',
        isCheckOut: true,
        expectedRecordId: 42,
      ),
      isTrue,
    );
  });
}

AttendanceRecord _attendanceRecord({
  required int id,
  String? checkOutDate,
  String? checkOutTime,
}) {
  return AttendanceRecord(
    id: id,
    empId: 'EMP001',
    branchId: 'BR001',
    checkInBranchId: 'BR001',
    checkOutBranchId: '',
    photoPath: 'attendance/photo.jpg',
    photoUrl: '',
    checkOutPhotoPath: '',
    checkOutPhotoUrl: '',
    latitude: 12.34,
    longitude: 56.78,
    checkInDate: '2026-09-03',
    checkInTime: '10:00:00',
    checkOutDate: checkOutDate,
    checkOutTime: checkOutTime,
    status: 'single_punch',
    statusLabel: 'Single Punch',
    isAdminOverride: false,
    isNightShift: false,
    isActiveSession: checkOutDate == null,
  );
}

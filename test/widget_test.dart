import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:frontend/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows employee login screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, _, {required rememberCredentials}) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.text('Attica Attendance'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Branch Id'), findsWidgets);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('scrolls compact login card to the sign in button', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, _, {required rememberCredentials}) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    await tester.ensureVisible(find.text('Sign In'));
    await tester.pump();

    expect(find.text('Sign In'), findsOneWidget);
  });
}

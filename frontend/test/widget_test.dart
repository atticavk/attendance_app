import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:frontend/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('constrains the complete web app viewport on wide screens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const EmployeePortalApp());

    final scaffoldRect = tester.getRect(find.byType(Scaffold).first);
    expect(scaffoldRect.width, lessThanOrEqualTo(1200));
    expect(scaffoldRect.center.dx, closeTo(960, 0.1));
  });

  testWidgets('shows employee login screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.text('Attica Attendance'), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Branch Id'), findsWidgets);
    expect(find.text('Password'), findsWidgets);
  });

  testWidgets('keeps login text fields outside transformed layout widgets', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    final loginFields = find.descendant(
      of: find.byKey(const Key('login-card')),
      matching: find.byType(TextFormField),
    );
    expect(loginFields, findsNWidgets(3));
    expect(
      find.ancestor(of: loginFields, matching: find.byType(FittedBox)),
      findsNothing,
    );
    expect(find.byType(SingleChildScrollView), findsWidgets);

    await tester.tap(loginFields.first);
    await tester.pump();
    final branchEditable = tester.widget<EditableText>(
      find.descendant(
        of: loginFields.first,
        matching: find.byType(EditableText),
      ),
    );
    expect(branchEditable.focusNode.hasFocus, isTrue);
  });

  testWidgets('fits compact login card with the sign in button visible', (
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
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    await tester.ensureVisible(find.text('Sign In'));
    await tester.pump();

    expect(find.text('Sign In'), findsOneWidget);
  });

  testWidgets('mobile login card fills its space and shows insight banner', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    final cardRect = tester.getRect(find.byKey(const Key('login-card')));
    final buttonRect = tester.getRect(find.byType(FilledButton));
    expect(find.text('CHECK IN FASTER'), findsOneWidget);
    expect(cardRect.bottom - buttonRect.bottom, lessThanOrEqualTo(30));
    expect(
      cardRect.bottom,
      closeTo(tester.getRect(find.byType(Scaffold)).bottom - 12, 0.1),
    );
  });

  testWidgets('keyboard collapses branding without overlapping login card', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Attica Attendance'), findsNothing);
    expect(find.text('Attendance, salary, and leave details.'), findsNothing);
    expect(find.text('CHECK IN FASTER'), findsNothing);
    final logoRect = tester.getRect(find.byType(Image).first);
    final cardRect = tester.getRect(find.byKey(const Key('login-card')));
    expect(cardRect.top, greaterThanOrEqualTo(logoRect.bottom));
    expect(find.text('Sign In'), findsOneWidget);
  });

  testWidgets('web login fields remain mounted when viewport insets change', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('login-card')),
        matching: find.byType(TextFormField),
      ),
      findsNWidgets(3),
    );
    expect(find.byKey(const Key('login-card')), findsOneWidget);
  });

  testWidgets('centers and constrains login form on wide screens', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    final formRect = tester.getRect(find.byType(Form));
    final cardRect = tester.getRect(find.byKey(const Key('login-card')));
    final headerRect = tester.getRect(
      find.byKey(const Key('login-header-background')),
    );
    expect(formRect.width, lessThanOrEqualTo(760));
    expect(formRect.center.dx, closeTo(960, 0.1));
    expect(headerRect.width, closeTo(cardRect.width, 0.1));
    expect(headerRect.center.dx, closeTo(cardRect.center.dx, 0.1));
  });

  testWidgets('keeps the complete sign in button visible on short desktops', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin:
              (
                _,
                _, {
                required password,
                required rememberCredentials,
                newPassword,
                newPasswordConfirmation,
              }) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    final scaffoldRect = tester.getRect(find.byType(Scaffold));
    final buttonRect = tester.getRect(find.byType(FilledButton));
    expect(buttonRect.bottom, lessThan(scaffoldRect.bottom));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lava_farm/features/farm/presentation/pages/farm_dashboard_page.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: FarmDashboardPage(enableAutoConnect: false),
        ),
      ),
    );
    await tester.pump();

    // App should render without crashing
    expect(find.byType(FarmDashboardPage), findsOneWidget);
  });
}

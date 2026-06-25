import 'package:flutter_test/flutter_test.dart';

import 'package:lava_farm/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const LavaFarmApp());
    await tester.pump();

    // App should render without crashing
    expect(find.byType(LavaFarmApp), findsOneWidget);
  });
}

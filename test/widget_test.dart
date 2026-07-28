import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:odys_service_tool/src/ui/brand.dart';

void main() {
  testWidgets('the mark paints at every needle position', (tester) async {
    // Out-of-range fractions are clamped, not asserted on: they come from
    // live speed divided by a fixed ceiling.
    for (final fraction in <double?>[null, 0, 0.5, 1, -2, 7]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: OdysMark(fraction: fraction))),
      ));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the filled variant paints', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: OdysMark(size: 96, filled: true)),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('page header shows the product name, title and trailing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PageHeader(
          title: 'Dashboard',
          trailing: Icon(Icons.settings),
        ),
      ),
    ));

    expect(find.text('ODYS SERVICE TOOL'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byType(OdysMark), findsOneWidget);
  });

  testWidgets('a long title does not overflow a narrow header',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: PageHeader(title: 'Firmware update in progress'),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}

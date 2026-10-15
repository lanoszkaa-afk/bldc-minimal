import 'package:flutter_test/flutter_test.dart';

import 'package:bldc_minimal/main.dart';

void main() {
  testWidgets('Aplikacja startuje i pokazuje nagłówek', (WidgetTester tester) async {
    await tester.pumpWidget(const BLDCFlywheelApp());
    expect(find.text('BLDC Flywheel'), findsOneWidget);
  });
}

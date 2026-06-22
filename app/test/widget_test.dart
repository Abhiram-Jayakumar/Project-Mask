import 'package:flutter_test/flutter_test.dart';

import 'package:project_mask/app.dart';

void main() {
  testWidgets('Home screen shows role choices', (WidgetTester tester) async {
    await tester.pumpWidget(const ProjectMaskApp());

    expect(find.text('Project Mask'), findsOneWidget);
    expect(find.text('Share my screen (Host)'), findsOneWidget);
    expect(find.text('Control a device (Viewer)'), findsOneWidget);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/presentation/image_thumbnail.dart';

void main() {
  testWidgets('loads a valid local PNG thumbnail', (tester) async {
    final path = File('test/fixtures/thumbnails/valid.png').absolute.path;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageThumbnail(path: path)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });

  testWidgets('shows a fallback for a missing image', (tester) async {
    final path = File('test/fixtures/thumbnails/missing.png').absolute.path;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageThumbnail(path: path)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });
}

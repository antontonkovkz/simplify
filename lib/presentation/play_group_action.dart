import 'dart:async';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../domain/library_item.dart';
import 'player_screens.dart';
import 'widgets.dart';

Future<void> playGroupAndOpenQueue(
  BuildContext context,
  AppController app,
  LibraryItem item,
) async {
  if (!context.mounted) return;
  unawaited(Navigator.push(context, slideRoute(QueueScreen(app: app))));
  try {
    await app.playGroup(item);
  } on Object catch (error) {
    app.message(AppController.friendly(error));
  }
}

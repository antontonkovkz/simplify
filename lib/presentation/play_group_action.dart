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
  final origin = ModalRoute.of(context);
  try {
    final started = await app.playGroup(item);
    if (!started || !context.mounted || origin?.isCurrent == false) return;
    unawaited(Navigator.push(context, slideRoute(QueueScreen(app: app))));
  } catch (error) {
    app.message(AppController.friendly(error));
  }
}

import 'package:flutter/material.dart';

/// Root navigator, for dialogs opened from outside the widget tree
/// (Explorer requests, the window close button).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Root messenger, so toasts can be shown from anywhere.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

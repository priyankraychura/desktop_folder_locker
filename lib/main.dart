import 'app/bootstrap.dart';

/// Entry point. Explorer passes `--open <vault>` or `--lock <path>`.
Future<void> main(List<String> args) => bootstrap(args);

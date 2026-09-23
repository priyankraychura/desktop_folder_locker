import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:path/path.dart' as p;

/// Keeps permission rules in memory instead of changing Windows
/// permissions. The real rules are tested in
/// `test/platform/access_control_test.dart` (Windows only).
class FakeAccessRules implements AccessRules {
  /// Rules by normalized path.
  final Map<String, AccessRule> rules = {};

  /// What [check] reports (`null` = rules are allowed).
  AccessProblem? problem;

  /// Makes [apply] fail, like Windows refusing the change.
  bool failApply = false;

  AccessRule? ruleOn(String path) => rules[p.normalize(path)];

  @override
  AccessProblem? check(String path) => problem;

  @override
  Future<void> apply(String path, AccessRule rule) async {
    if (failApply) {
      throw AccessControlException(
        AccessProblem.failed,
        errorCode: 5,
        path: path,
      );
    }
    rules[p.normalize(path)] = rule;
  }

  @override
  Future<void> remove(String path) async => rules.remove(p.normalize(path));
}

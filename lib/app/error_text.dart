import '../core/constants/app_info.dart';
import '../engine/engine_exception.dart';
import '../features/auth/application/session_controller.dart';
import '../features/items/application/path_guard.dart';
import '../features/items/application/protection_controller.dart';

/// Turns any error into a short sentence a user can act on.
String errorText(Object error) => switch (error) {
  EngineException() => _engine(error),
  ProtectionException(:final issue, :final pathProblem) =>
    issue == ProtectionIssue.pathNotAllowed && pathProblem != null
        ? pathProblemText(pathProblem)
        : _protection(issue),
  InvalidRecoveryKeyException() =>
    'That recovery key is not correct. Check for typos and try again.',
  _ => 'Something unexpected went wrong ($error).',
};

String pathProblemText(PathProblem problem) => switch (problem) {
  PathProblem.notFound => 'This item doesn\'t exist anymore.',
  PathProblem.driveRoot =>
    'Whole drives can\'t be locked. Choose a folder instead.',
  PathProblem.systemLocation =>
    'System folders can\'t be locked, because Windows and your apps need '
        'them.',
  PathProblem.userFolderRoot =>
    'Main user folders like Documents or Desktop can\'t be locked. Create a '
        'folder inside them and lock that instead.',
  PathProblem.appFolder => '${AppInfo.name}\'s own folders can\'t be locked.',
  PathProblem.isVault =>
    'This is already a locked vault. Double-click it to unlock it.',
  PathProblem.isLink =>
    'Shortcuts and links can\'t be locked. Lock the real folder instead.',
  PathProblem.alreadyProtected => 'This item is already in your list.',
  PathProblem.insideProtectedItem =>
    'This is inside an item that is already in your list.',
  PathProblem.containsProtectedItem =>
    'This folder contains an item that is already in your list. Unlock and '
        'remove that item first.',
};

String _protection(ProtectionIssue issue) => switch (issue) {
  ProtectionIssue.pathNotAllowed => 'This item can\'t be protected.',
  ProtectionIssue.appLocked => 'Unlock ${AppInfo.name} first.',
  ProtectionIssue.passwordRequired => 'A password is needed for this item.',
  ProtectionIssue.busy =>
    'Please wait until the current operation has finished.',
  ProtectionIssue.notFound =>
    'The item could not be found. It may have been moved, renamed or '
        'deleted, or its drive is disconnected.',
  ProtectionIssue.stillProtected =>
    'Unlock this item before removing it from the list.',
  ProtectionIssue.hideFailed =>
    'Windows did not allow hiding or showing this item.',
};

String _engine(EngineException error) => switch (error.code) {
  EngineErrorCode.wrongPassword => 'That password is not correct.',
  EngineErrorCode.inUse =>
    'A file in this item is open in another program. Close it and try '
        'again.',
  EngineErrorCode.accessDenied =>
    'Windows denied access. Check that you are allowed to change this item.',
  EngineErrorCode.notFound =>
    'The item could not be found. It may have been moved or deleted.',
  EngineErrorCode.alreadyExists =>
    'Something with the same name is in the way. Rename it and try again.',
  EngineErrorCode.protectedLocation => 'This location can\'t be locked.',
  EngineErrorCode.unsupportedContent =>
    'This item contains something that can\'t be locked yet (for example a '
        'link to another folder, or an unusual file name).',
  EngineErrorCode.diskFull =>
    'There isn\'t enough free space on this drive. Locking needs about as '
        'much free space as the item\'s size.',
  EngineErrorCode.corruptVault =>
    'This vault is damaged or was modified, so it can\'t be opened.',
  EngineErrorCode.unsupportedVersion =>
    'This vault was made by a newer version of ${AppInfo.name}. Update the '
        'app to open it.',
  EngineErrorCode.cancelled => 'Cancelled. Nothing was changed.',
  EngineErrorCode.ioError =>
    'Something went wrong while reading or writing files. '
        '(${error.message})',
};

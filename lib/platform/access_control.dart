import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows/win32_security.dart';

// File access rights (winnt.h).
const int _readData = 0x1; // also "list folder"
const int _writeData = 0x2; // also "create files"
const int _appendData = 0x4; // also "create folders"
const int _readEa = 0x8;
const int _writeEa = 0x10;
const int _execute = 0x20; // also "traverse folder"
const int _deleteChild = 0x40;
const int _writeAttributes = 0x100;
const int _delete = 0x10000;

const int _readOnlyMask =
    _writeData |
    _appendData |
    _writeEa |
    _deleteChild |
    _writeAttributes |
    _delete;
const int _blockAllMask = _readOnlyMask | _readData | _readEa | _execute;

/// A Windows permission rule ("deny Everyone") that the app puts on a file
/// or folder. Inside a folder, every file and subfolder inherits it.
///
/// Reading attributes and reading or changing permissions are never
/// denied: Explorer can still show the item, and its owner can always
/// remove the rule again.
enum AccessRule {
  /// Nobody can open, change or delete it.
  blockAll(_blockAllMask),

  /// It can be opened and read, but not changed or deleted.
  readOnly(_readOnlyMask);

  const AccessRule(this.mask);

  final int mask;
}

/// Why a rule can't be put on an item.
enum AccessProblem {
  /// Not running on Windows.
  unsupported,

  /// The drive has no permissions (FAT32, exFAT…).
  noPermissionsOnDrive,

  /// Someone else owns the item, so the rule might not be removable later.
  notOwner,

  /// The item has no permission list at all ("everyone can do anything");
  /// a rule added to it could not be undone cleanly.
  noPermissionList,

  /// Windows refused the change (the error code says why).
  failed,
}

class AccessControlException implements Exception {
  const AccessControlException(this.problem, {this.errorCode, this.path});

  final AccessProblem problem;

  /// Win32 error code, for [AccessProblem.failed].
  final int? errorCode;
  final String? path;

  @override
  String toString() =>
      'AccessControlException(${problem.name}, code: $errorCode, $path)';
}

/// Adds and removes the app's [AccessRule]s with the Win32 security API.
///
/// Rules are only added to items the current user owns: the owner can
/// always read and change permissions, whatever the rules say, so a rule
/// can never lock its owner out for good.
abstract final class AccessControl {
  static bool get isSupported => Platform.isWindows;

  /// Why [path] can't get a rule, or `null` if it can.
  static AccessProblem? check(String path) {
    if (!isSupported) return AccessProblem.unsupported;
    if (!_driveHasPermissions(path)) return AccessProblem.noPermissionsOnDrive;
    return using((arena) {
      final info = _read(path, arena);
      try {
        if (!_callerOwns(info.owner, arena)) return AccessProblem.notOwner;
        return info.dacl == nullptr ? AccessProblem.noPermissionList : null;
      } finally {
        Win32Security.localFree(info.descriptor);
      }
    });
  }

  /// Puts [rule] on [path], replacing a rule the app added before.
  ///
  /// Windows copies the rule to everything inside a folder, which takes a
  /// moment for big folders: call this from a background isolate.
  static void apply(String path, AccessRule rule) {
    final problem = check(path);
    if (problem != null) throw AccessControlException(problem, path: path);
    using((arena) {
      final info = _read(path, arena);
      try {
        final everyone = _everyone(arena);
        final acl = _rebuild(
          arena,
          info.dacl,
          everyone,
          add: rule,
          isDirectory: FileSystemEntity.isDirectorySync(path),
        );
        _write(path, acl, arena);
      } finally {
        Win32Security.localFree(info.descriptor);
      }
    });
  }

  /// Removes the rule the app added to [path], if there is one. Other
  /// permissions are left untouched.
  static void remove(String path) {
    if (!isSupported) return;
    using((arena) {
      final info = _read(path, arena);
      try {
        if (info.dacl == nullptr) return;
        final everyone = _everyone(arena);
        if (_findRule(info.dacl, everyone, arena) == null) return;
        final acl = _rebuild(
          arena,
          info.dacl,
          everyone,
          isDirectory: FileSystemEntity.isDirectorySync(path),
        );
        _write(path, acl, arena);
      } finally {
        Win32Security.localFree(info.descriptor);
      }
    });
  }

  /// The rule the app added to [path], or `null`.
  static AccessRule? current(String path) {
    if (!isSupported) return null;
    return using((arena) {
      final info = _read(path, arena);
      try {
        if (info.dacl == nullptr) return null;
        return _findRule(info.dacl, _everyone(arena), arena);
      } finally {
        Win32Security.localFree(info.descriptor);
      }
    });
  }

  // -------------------------------------------------------------------------

  /// Long paths need the `\\?\` prefix for the Win32 API.
  static Pointer<Utf16> _nativePath(String path, Arena arena) {
    final long = path.length >= 240 && !path.startsWith(r'\\?\');
    final full = !long
        ? path
        : path.startsWith(r'\\')
        ? '\\\\?\\UNC\\${path.substring(2)}'
        : '\\\\?\\$path';
    return full.toNativeUtf16(allocator: arena);
  }

  static bool _driveHasPermissions(String path) => using((arena) {
    const bufferLength = 1024;
    final volume = arena<Uint16>(bufferLength).cast<Utf16>();
    if (Win32Security.getVolumePathName(
          _nativePath(path, arena),
          volume,
          bufferLength,
        ) ==
        0) {
      return false;
    }
    final flags = arena<Uint32>();
    final ok = Win32Security.getVolumeInformation(
      volume,
      nullptr,
      0,
      nullptr,
      nullptr,
      flags,
      nullptr,
      0,
    );
    return ok != 0 && (flags.value & Win32Security.filePersistentAcls) != 0;
  });

  static _SecurityInfo _read(String path, Arena arena) {
    final owner = arena<Pointer<Void>>();
    final dacl = arena<Pointer<Void>>();
    final descriptor = arena<Pointer<Void>>();
    final error = Win32Security.getNamedSecurityInfo(
      _nativePath(path, arena),
      Win32Security.seFileObject,
      Win32Security.ownerSecurityInformation |
          Win32Security.daclSecurityInformation,
      owner,
      nullptr,
      dacl,
      nullptr,
      descriptor,
    );
    if (error != 0) {
      throw AccessControlException(
        AccessProblem.failed,
        errorCode: error,
        path: path,
      );
    }
    return _SecurityInfo(owner.value, dacl.value, descriptor.value);
  }

  static void _write(String path, Pointer<Void> acl, Arena arena) {
    final error = Win32Security.setNamedSecurityInfo(
      _nativePath(path, arena),
      Win32Security.seFileObject,
      Win32Security.daclSecurityInformation,
      nullptr,
      nullptr,
      acl,
      nullptr,
    );
    if (error != 0) {
      throw AccessControlException(
        AccessProblem.failed,
        errorCode: error,
        path: path,
      );
    }
  }

  /// Whether [owner] is the current user, or a group that is enabled in
  /// the current user's token (an elevated administrator owns items as
  /// "Administrators").
  static bool _callerOwns(Pointer<Void> owner, Arena arena) {
    if (owner == nullptr) return false;
    final isMember = arena<Int32>();
    return Win32Security.checkTokenMembership(nullptr, owner, isMember) != 0 &&
        isMember.value != 0;
  }

  static Pointer<Void> _everyone(Arena arena) {
    final size = arena<Uint32>()..value = Win32Security.securityMaxSidSize;
    final sid = arena<Uint8>(Win32Security.securityMaxSidSize).cast<Void>();
    if (Win32Security.createWellKnownSid(
          Win32Security.winWorldSid,
          nullptr,
          sid,
          size,
        ) ==
        0) {
      throw const AccessControlException(AccessProblem.failed);
    }
    return sid;
  }

  static AccessRule? _findRule(
    Pointer<Void> dacl,
    Pointer<Void> everyone,
    Arena arena,
  ) {
    final (:aceCount, bytesInUse: _) = _sizeOf(dacl, arena);
    final ace = arena<Pointer<Void>>();
    for (var i = 0; i < aceCount; i++) {
      if (Win32Security.getAce(dacl, i, ace) == 0) break;
      if (_ruleOf(ace.value, everyone) case final rule?) return rule;
    }
    return null;
  }

  /// The app's rule stored in [ace]: an explicit (not inherited) deny entry
  /// for Everyone with one of the [AccessRule] masks.
  static AccessRule? _ruleOf(Pointer<Void> ace, Pointer<Void> everyone) {
    final header = ace.cast<Uint8>();
    if (header[0] != Win32Security.accessDeniedAceType) return null;
    if (header[1] & Win32Security.inheritedAce != 0) return null;
    final sid = Pointer<Void>.fromAddress(ace.address + 8);
    if (Win32Security.equalSid(sid, everyone) == 0) return null;
    final mask = ace.cast<Uint32>()[1];
    for (final rule in AccessRule.values) {
      if (rule.mask == mask) return rule;
    }
    return null;
  }

  static ({int aceCount, int bytesInUse}) _sizeOf(
    Pointer<Void> dacl,
    Arena arena,
  ) {
    // ACL_SIZE_INFORMATION: AceCount, AclBytesInUse, AclBytesFree.
    final info = arena<Uint32>(3);
    if (Win32Security.getAclInformation(
          dacl,
          info.cast(),
          12,
          Win32Security.aclSizeInformation,
        ) ==
        0) {
      throw const AccessControlException(AccessProblem.failed);
    }
    return (aceCount: info[0], bytesInUse: info[1]);
  }

  /// A copy of [dacl] without the app's rules, with [add] as the first
  /// entry (deny entries come first, as Windows expects).
  static Pointer<Void> _rebuild(
    Arena arena,
    Pointer<Void> dacl,
    Pointer<Void> everyone, {
    required bool isDirectory,
    AccessRule? add,
  }) {
    if (dacl == nullptr) {
      throw const AccessControlException(AccessProblem.noPermissionList);
    }
    final (:aceCount, :bytesInUse) = _sizeOf(dacl, arena);
    final revision = dacl.cast<Uint8>()[0];
    final extra = add == null ? 0 : 8 + Win32Security.getLengthSid(everyone);
    final size = (bytesInUse + extra + 3) & ~3;
    final acl = arena<Uint8>(size).cast<Void>();
    if (Win32Security.initializeAcl(acl, size, revision) == 0) {
      throw const AccessControlException(AccessProblem.failed);
    }
    if (add != null) {
      final flags = isDirectory
          ? Win32Security.objectInheritAce | Win32Security.containerInheritAce
          : 0;
      if (Win32Security.addAccessDeniedAceEx(
            acl,
            revision,
            flags,
            add.mask,
            everyone,
          ) ==
          0) {
        throw const AccessControlException(AccessProblem.failed);
      }
    }
    final ace = arena<Pointer<Void>>();
    for (var i = 0; i < aceCount; i++) {
      if (Win32Security.getAce(dacl, i, ace) == 0) {
        throw const AccessControlException(AccessProblem.failed);
      }
      if (_ruleOf(ace.value, everyone) != null) continue;
      final aceSize = ace.value.cast<Uint16>()[1];
      if (Win32Security.addAce(
            acl,
            revision,
            Win32Security.maxDword,
            ace.value,
            aceSize,
          ) ==
          0) {
        throw const AccessControlException(AccessProblem.failed);
      }
    }
    return acl;
  }
}

class _SecurityInfo {
  const _SecurityInfo(this.owner, this.dacl, this.descriptor);

  /// Point into [descriptor], which must be freed with `LocalFree`.
  final Pointer<Void> owner;
  final Pointer<Void> dacl;
  final Pointer<Void> descriptor;
}

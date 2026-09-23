import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Win32 functions for reading and changing NTFS permissions (ACLs).
///
/// Only call these on Windows. [AccessControl] wraps them in a safe API.
abstract final class Win32Security {
  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  // SE_OBJECT_TYPE and SECURITY_INFORMATION.
  static const int seFileObject = 1;
  static const int ownerSecurityInformation = 0x1;
  static const int daclSecurityInformation = 0x4;

  // ACE types and flags.
  static const int accessDeniedAceType = 1;
  static const int objectInheritAce = 0x1;
  static const int containerInheritAce = 0x2;
  static const int inheritedAce = 0x10;

  static const int winWorldSid = 1;
  static const int aclSizeInformation = 2;
  static const int securityMaxSidSize = 68;
  static const int maxDword = 0xFFFFFFFF;
  static const int filePersistentAcls = 0x8;

  static final int Function(
    Pointer<Utf16>,
    int,
    int,
    Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>,
  )
  getNamedSecurityInfo = _advapi32
      .lookupFunction<
        Uint32 Function(
          Pointer<Utf16>,
          Int32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        )
      >('GetNamedSecurityInfoW');

  static final int Function(
    Pointer<Utf16>,
    int,
    int,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
  )
  setNamedSecurityInfo = _advapi32
      .lookupFunction<
        Uint32 Function(
          Pointer<Utf16>,
          Int32,
          Uint32,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('SetNamedSecurityInfoW');

  static final int Function(Pointer<Void>, Pointer<Void>, int, int)
  getAclInformation = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Int32),
        int Function(Pointer<Void>, Pointer<Void>, int, int)
      >('GetAclInformation');

  static final int Function(Pointer<Void>, int, int) initializeAcl = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Uint32),
        int Function(Pointer<Void>, int, int)
      >('InitializeAcl');

  static final int Function(Pointer<Void>, int, int, int, Pointer<Void>)
  addAccessDeniedAceEx = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, int, int, Pointer<Void>)
      >('AddAccessDeniedAceEx');

  static final int Function(Pointer<Void>, int, int, Pointer<Void>, int)
  addAce = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, int, Pointer<Void>, int)
      >('AddAce');

  static final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>) getAce =
      _advapi32.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('GetAce');

  static final int Function(Pointer<Void>, Pointer<Void>) equalSid = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('EqualSid');

  static final int Function(Pointer<Void>) getLengthSid = _advapi32
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GetLengthSid');

  static final int Function(int, Pointer<Void>, Pointer<Void>, Pointer<Uint32>)
  createWellKnownSid = _advapi32
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Void>, Pointer<Void>, Pointer<Uint32>)
      >('CreateWellKnownSid');

  static final int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)
  checkTokenMembership = _advapi32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)
      >('CheckTokenMembership');

  static final Pointer<Void> Function(Pointer<Void>) localFree = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  static final int Function(Pointer<Utf16>, Pointer<Utf16>, int)
  getVolumePathName = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('GetVolumePathNameW');

  static final int Function(
    Pointer<Utf16>,
    Pointer<Utf16>,
    int,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Utf16>,
    int,
  )
  getVolumeInformation = _kernel32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Utf16>,
          Uint32,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Utf16>,
          int,
        )
      >('GetVolumeInformationW');
}

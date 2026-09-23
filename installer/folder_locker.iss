; Inno Setup script for Folder Locker (https://jrsoftware.org/isinfo.php).
;
; Build the app first, then compile this script:
;
;   flutter build windows --release
;   "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 installer\folder_locker.iss
;
; The installer is written to build\installer. CI does all of this (see
; .github/workflows/ci.yml).
;
; It installs for the current user only (no administrator rights), into
; %LOCALAPPDATA%\Programs\Folder Locker, and registers the same Explorer
; entries as lib/platform/explorer_integration.dart. Keep both in sync.

#define AppName "Folder Locker"
#define AppExeName "folder_locker.exe"
#define AppPublisher "Priyank Raychura"
#define AppUrl "https://github.com/priyankraychura/desktop_folder_locker"
#define BuildDir "..\build\windows\x64\runner\Release"
#define VaultProgId "FolderLocker.Vault"
#define LockVerb "FolderLocker.Lock"
; Resource id of the vault icon in the exe (windows/runner/resource.h).
#define VaultIconId "102"

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
; Never change AppId: Windows uses it to find the installed app for updates.
AppId={{EEDC761A-C5AA-42F5-985B-00DE48C4C4F2}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=FolderLocker-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Close a running copy before replacing its files.
CloseApplications=yes
RestartApplications=no
; Tell Explorer to refresh file icons after the .flk association changes.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; HKA is HKEY_CURRENT_USER here, because the install is per user.
; .flk vault files: lock icon, and double-click opens the password dialog.
Root: HKA; Subkey: "Software\Classes\.flk"; ValueType: string; ValueName: ""; ValueData: "{#VaultProgId}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\{#VaultProgId}"; ValueType: string; ValueName: ""; ValueData: "Locked item"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#VaultProgId}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"",-{#VaultIconId}"
Root: HKA; Subkey: "Software\Classes\{#VaultProgId}\shell"; ValueType: string; ValueName: ""; ValueData: "open"
Root: HKA; Subkey: "Software\Classes\{#VaultProgId}\shell\open"; ValueType: string; ValueName: ""; ValueData: "Unlock with {#AppName}"
Root: HKA; Subkey: "Software\Classes\{#VaultProgId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --open ""%1"""
; "Lock with Folder Locker" in the right-click menu of folders and files.
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""
Root: HKA; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKA; Subkey: "Software\Classes\*\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Settings, keys and journals in %APPDATA%\FolderLocker are kept on purpose:
; they are needed to find the user's items again after reinstalling.

[Code]
function InitializeUninstall(): Boolean;
begin
  Result := SuppressibleMsgBox(
    'Your data stays safe after {#AppName} is removed:' + #13#10 + #13#10 +
    '- Locked items stay encrypted. Install {#AppName} again to open them ' +
    'with your password or recovery key.' + #13#10 +
    '- Unlocked items stay normal folders and files.' + #13#10 +
    '- Your settings in %APPDATA%\FolderLocker are kept.' + #13#10 + #13#10 +
    'Uninstall {#AppName} now?',
    mbConfirmation, MB_YESNO, IDYES) = IDYES;
end;

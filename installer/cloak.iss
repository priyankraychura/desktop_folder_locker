; Inno Setup script for Cloak (https://jrsoftware.org/isinfo.php).
;
; Build the drive helper, the Explorer plug-in and the app, and fetch
; Dokany, then compile this script:
;
;   cargo build --release -p cloak-drive -p cloak-shell   (in native\)
;   flutter build windows --release                  (copies both next to the app)
;   pwsh installer\get-dokany.ps1 -Destination build\windows\x64\runner\Release\dokany
;   "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.3.1 installer\cloak.iss
;
; The installer is written to build\installer. CI does all of this (see
; .github/workflows/ci.yml). Without the Dokany step, the installer links to
; the Dokany download instead of installing it. Without the plug-in, the
; right-click entry is the plain "Lock with Cloak".
;
; It installs for all users into Program Files (one administrator prompt),
; or, if the user chooses, for them only into %LOCALAPPDATA%\Programs
; without one. Either way it registers the same Explorer entries as
; lib/platform/explorer_integration.dart for the user installing it. Keep
; both in sync.

#define AppName "Cloak"
#define AppExeName "cloak.exe"
#define AppPublisher "Priyank Raychura"
#define AppUrl "https://github.com/priyankraychura/desktop_folder_locker"
#define BuildDir "..\build\windows\x64\runner\Release"
#define VaultProgId "FolderLocker.Vault"
#define LockVerb "FolderLocker.Lock"
; Resource id of the vault icon in the exe (windows/runner/resource.h).
#define VaultIconId "102"
; Dokany's installer, next to the app (see get-dokany.ps1).
#define DokanyMsi "dokany\Dokan_x64.msi"
; The Explorer plug-in (native\shell) and its class id (CLSID_MENU in
; native\shell\src\com.rs). In sections, "{{" stands for "{".
#define ShellDll "cloak_shell.dll"
#define ShellClsid "{{3C1C048E-1C62-4B0B-87AC-55EDAD0E97BB}"
; The plug-in's lock badge (CLSID_BADGE). Windows uses the first 15 icon
; overlays by name, so its name starts with a space.
#define BadgeClsid "{{38F771FD-E77E-4105-A560-9E02A7B507D5}"
#define BadgeName " FolderLocker"
; The app was called Folder Locker before. An update removes the files and
; shortcuts of that name (see [InstallDelete] and MovePluginAway). The
; registry ids above and the data folder keep that name.
#define OldAppName "Folder Locker"
#define OldExeName "folder_locker.exe"
#define OldHelperName "folder_locker_drive.exe"
#define OldShellDll "folder_locker_shell.dll"

#if FileExists(AddBackslash(SourcePath) + BuildDir + "\" + DokanyMsi)
  #define BundleDokany
#endif
#if FileExists(AddBackslash(SourcePath) + BuildDir + "\" + ShellDll)
  #define ShellPlugin
#endif

#ifndef AppVersion
  #define AppVersion "1.3.1"
#endif

[Setup]
; Never change AppId: Windows uses it to find the installed app for updates.
AppId={{EEDC761A-C5AA-42F5-985B-00DE48C4C4F2}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppCopyright=Copyright (C) 2026 {#AppPublisher}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
; For all users by default: one administrator prompt, which also covers
; installing Dokany. "Install for me only" needs none.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
; The Explorer entries are per user on purpose (see [Registry]).
UsedUserAreasWarning=no
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=Cloak-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Close a running copy before replacing its files. Not Explorer, which
; loads the plug-in: see MovePluginAway in [Code]. Force: a copy that
; doesn't quit when asked (1.3.0 and older hide in the notification area
; instead) is ended, rather than failing with "DeleteFile failed; code 5".
CloseApplications=force
CloseApplicationsFilter=*.exe,*.chm
RestartApplications=no
; Tell Explorer to refresh file icons after the .flk association changes.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
#ifdef BundleDokany
; Only offered when Dokany is missing.
Name: "dokany"; Description: "Install Dokany, a free driver that opens encrypted folders as drives"; GroupDescription: "Encrypted drives:"; Check: DokanyMissing
#endif

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Excludes: "\{#ShellDll}"; Flags: ignoreversion recursesubdirs createallsubdirs
; The GPL goes along with the app.
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
#ifdef ShellPlugin
; Explorer may have it loaded: see MovePluginAway in [Code].
Source: "{#BuildDir}\{#ShellDll}"; DestDir: "{app}"; Flags: ignoreversion restartreplace uninsrestartdelete
#endif

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Per user (HKCU) in both install modes, like the app writes them: the
; Explorer integration setting of each user turns them on and off. The app
; adds them for other users when they first start it.
; .flk vault files: lock icon, and double-click opens the password dialog.
Root: HKCU; Subkey: "Software\Classes\.flk"; ValueType: string; ValueName: ""; ValueData: "{#VaultProgId}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\{#VaultProgId}"; ValueType: string; ValueName: ""; ValueData: "Locked item"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#VaultProgId}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"",-{#VaultIconId}"
Root: HKCU; Subkey: "Software\Classes\{#VaultProgId}\shell"; ValueType: string; ValueName: ""; ValueData: "open"
Root: HKCU; Subkey: "Software\Classes\{#VaultProgId}\shell\open"; ValueType: string; ValueName: ""; ValueData: "Unlock with {#AppName}"
Root: HKCU; Subkey: "Software\Classes\{#VaultProgId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --open ""%1"""
; The right-click entry (written anew: see RemoveExplorerEntry in [Code]).
#ifdef ShellPlugin
; The Explorer plug-in's entry on folders, files and drives, which follows
; each item: Lock, Unlock or Open with Cloak.
Root: HKCU; Subkey: "Software\Classes\CLSID\{#ShellClsid}"; ValueType: string; ValueName: ""; ValueData: "{#AppName} Explorer plug-in"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\CLSID\{#ShellClsid}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\{#ShellDll}"
Root: HKCU; Subkey: "Software\Classes\CLSID\{#ShellClsid}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Apartment"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: "ExplorerCommandHandler"; ValueData: "{#ShellClsid}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: "ExplorerCommandHandler"; ValueData: "{#ShellClsid}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Drive\shell\{#LockVerb}"; ValueType: string; ValueName: "ExplorerCommandHandler"; ValueData: "{#ShellClsid}"; Flags: uninsdeletekey
; The lock badge on blocked, read-only and hidden items: an icon overlay,
; which Windows only takes from the machine's settings, so only when
; installing for all users. Explorer loads it when it starts. The plug-in
; shows it to each user whose Explorer integration setting is on.
Root: HKLM; Subkey: "Software\Classes\CLSID\{#BadgeClsid}"; ValueType: string; ValueName: ""; ValueData: "{#AppName} lock badge"; Flags: uninsdeletekey; Check: IsAdminInstallMode
Root: HKLM; Subkey: "Software\Classes\CLSID\{#BadgeClsid}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\{#ShellDll}"; Check: IsAdminInstallMode
Root: HKLM; Subkey: "Software\Classes\CLSID\{#BadgeClsid}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Apartment"; Check: IsAdminInstallMode
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\{#BadgeName}"; ValueType: string; ValueName: ""; ValueData: "{#BadgeClsid}"; Flags: uninsdeletekey; Check: IsAdminInstallMode
#else
; "Lock with Cloak" on folders and files.
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""
#endif

[InstallDelete]
; Copies of the plug-in that were in use last time (see MovePluginAway).
Type: files; Name: "{app}\{#ShellDll}.*.old"
Type: files; Name: "{app}\{#OldShellDll}.*.old"
; The app under its old name.
Type: files; Name: "{app}\{#OldExeName}"
Type: files; Name: "{app}\{#OldHelperName}"
Type: files; Name: "{autoprograms}\{#OldAppName}.lnk"
Type: files; Name: "{autodesktop}\{#OldAppName}.lnk"

[UninstallDelete]
Type: files; Name: "{app}\{#ShellDll}.*.old"
Type: files; Name: "{app}\{#OldShellDll}.*.old"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
#ifndef BundleDokany
; Without the bundled Dokany, link to its download instead.
Filename: "https://github.com/dokan-dev/dokany/releases/latest"; Description: "Get Dokany (free), to open encrypted folders as drives"; Flags: postinstall shellexec nowait skipifsilent unchecked
#endif

; Settings, keys and journals in %APPDATA%\FolderLocker are kept on purpose:
; they are needed to find the user's items again after reinstalling.

[Code]
#ifdef BundleDokany
var
  DokanyNeedsRestart: Boolean;

{ Dokany 2 puts its library into System32 (the 64-bit one in 64-bit mode). }
function DokanyMissing: Boolean;
begin
  Result := not FileExists(ExpandConstant('{sys}\dokan2.dll'));
end;

{ Runs the bundled Dokany installer: silently when Setup runs as
  administrator, otherwise with its own administrator prompt. }
procedure InstallDokany;
var
  Msi, LogFile, Params: String;
  Started: Boolean;
  ResultCode: Integer;
begin
  Msi := ExpandConstant('{app}\{#DokanyMsi}');
  LogFile := ExpandConstant('{%TEMP}\Cloak-Dokany.log');
  WizardForm.StatusLabel.Caption := 'Installing Dokany...';
  WizardForm.ProgressGauge.Style := npbstMarquee;
  try
    if IsAdminInstallMode then
    begin
      Params := '/i "' + Msi + '" /qn /norestart /l*v "' + LogFile + '"';
      Started := Exec(ExpandConstant('{sys}\msiexec.exe'), Params, '',
        SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end
    else
    begin
      Params := '/i "' + Msi + '" /passive /norestart /l*v "' + LogFile + '"';
      Started := ShellExec('runas', ExpandConstant('{sys}\msiexec.exe'), Params,
        '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
    end;
  finally
    WizardForm.ProgressGauge.Style := npbstNormal;
  end;
  if Started then
    Log('Dokany installer exit code: ' + IntToStr(ResultCode))
  else
    Log('Dokany installer did not start: ' + SysErrorMessage(ResultCode));

  { 3010: installed, a restart finishes it. 1641: a restart was started. }
  if Started and ((ResultCode = 3010) or (ResultCode = 1641)) then
    DokanyNeedsRestart := True
  else if not Started or (ResultCode <> 0) then
    SuppressibleMsgBox(
      'Dokany could not be installed (code ' + IntToStr(ResultCode) +
      ').' + #13#10 + #13#10 +
      'Everything else works. To open encrypted folders as drives, install ' +
      'Dokany later in {#AppName}: Settings, Encrypted drives.' + #13#10 +
      'Details: ' + LogFile,
      mbInformation, MB_OK, IDOK);
end;

function NeedRestart(): Boolean;
begin
  Result := DokanyNeedsRestart;
end;
#endif

{ Removes the right-click entry of this or another version (with or
  without the plug-in), so that [Registry] writes it anew, like the app
  does. }
procedure RemoveExplorerEntry;
begin
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\Directory\shell\{#LockVerb}');
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\*\shell\{#LockVerb}');
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\Drive\shell\{#LockVerb}');
  RegDeleteKeyIncludingSubkeys(HKCU,
    ExpandConstant('Software\Classes\CLSID\{#ShellClsid}'));
end;

{ Explorer keeps the plug-in loaded while it's in use, and a loaded DLL
  can't be replaced or deleted. It can be renamed, though: Explorer goes on
  with the old copy until it restarts, and loads the new one next time. The
  old copy goes to the temporary folder, or stays next to the app until the
  next update (see the InstallDelete section). Where Setup may, Windows
  deletes it when it restarts. So neither updating nor uninstalling needs a
  restart. }
procedure MoveAway(Dll: String);
var
  Stamp, Old: String;
  Moved: Boolean;
begin
  if not FileExists(Dll) or DeleteFile(Dll) then
    Exit;
  Stamp := GetDateTimeString('yyyymmddhhnnsszzz', #0, #0);
  Old := ExpandConstant('{%TEMP}\Cloak-plugin-') + Stamp + '.dll.old';
  Moved := RenameFile(Dll, Old);
  if not Moved then
  begin
    Old := Dll + '.' + Stamp + '.old';
    Moved := RenameFile(Dll, Old);
  end;
  if Moved then
  begin
    Log('The Explorer plug-in was in use. Moved it to ' + Old);
    if IsAdmin then
      RestartReplace(Old, '');
  end
  else
    Log('The Explorer plug-in is in use and could not be moved.');
end;

{ The plug-in, and its copy from when the app had its old name. }
procedure MovePluginAway;
begin
  MoveAway(ExpandConstant('{app}\{#ShellDll}'));
  MoveAway(ExpandConstant('{app}\{#OldShellDll}'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    RemoveExplorerEntry;
    MovePluginAway;
  end;
#ifdef BundleDokany
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('dokany') then
    InstallDokany;
#endif
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    MovePluginAway;
end;

function InitializeUninstall(): Boolean;
begin
  Result := SuppressibleMsgBox(
    'Your data stays safe after {#AppName} is removed:' + #13#10 + #13#10 +
    '- Locked items stay encrypted. Install {#AppName} again to open them ' +
    'with your password or recovery key.' + #13#10 +
    '- Encrypted drives (.flkd folders) stay encrypted too.' + #13#10 +
    '- Blocked and read-only items stay protected. Unlock them first, or ' +
    'install {#AppName} again to unlock them.' + #13#10 +
    '- Hidden items stay hidden. Show them first, or install {#AppName} ' +
    'again to show them.' + #13#10 +
    '- Unlocked items stay normal folders and files.' + #13#10 +
    '- Your settings in %APPDATA%\FolderLocker are kept.' + #13#10 +
    '- Dokany stays installed, as other apps may use it. You can remove it ' +
    'in Windows Settings, Apps.' + #13#10 + #13#10 +
    'Uninstall {#AppName} now?',
    mbConfirmation, MB_YESNO, IDYES) = IDYES;
end;

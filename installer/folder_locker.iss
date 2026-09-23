; Inno Setup script for Folder Locker (https://jrsoftware.org/isinfo.php).
;
; Build the drive helper and the app, and fetch Dokany, then compile this
; script:
;
;   cargo build --release -p folder-locker-drive     (in native\)
;   flutter build windows --release                  (copies the helper)
;   pwsh installer\get-dokany.ps1 -Destination build\windows\x64\runner\Release\dokany
;   "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.2.0 installer\folder_locker.iss
;
; The installer is written to build\installer. CI does all of this (see
; .github/workflows/ci.yml). Without the Dokany step, the installer links to
; the Dokany download instead of installing it.
;
; It installs for all users into Program Files (one administrator prompt),
; or, if the user chooses, for them only into %LOCALAPPDATA%\Programs
; without one. Either way it registers the same Explorer entries as
; lib/platform/explorer_integration.dart for the user installing it. Keep
; both in sync.

#define AppName "Folder Locker"
#define AppExeName "folder_locker.exe"
#define AppPublisher "Priyank Raychura"
#define AppUrl "https://github.com/priyankraychura/desktop_folder_locker"
#define BuildDir "..\build\windows\x64\runner\Release"
#define VaultProgId "FolderLocker.Vault"
#define LockVerb "FolderLocker.Lock"
; Resource id of the vault icon in the exe (windows/runner/resource.h).
#define VaultIconId "102"
; Dokany's installer, next to the app (see get-dokany.ps1).
#define DokanyMsi "dokany\Dokan_x64.msi"

#if FileExists(AddBackslash(SourcePath) + BuildDir + "\" + DokanyMsi)
  #define BundleDokany
#endif

#ifndef AppVersion
  #define AppVersion "1.2.0"
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
#ifdef BundleDokany
; Only offered when Dokany is missing.
Name: "dokany"; Description: "Install Dokany, a free driver that opens encrypted folders as drives"; GroupDescription: "Encrypted drives:"; Check: DokanyMissing
#endif

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

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
; "Lock with Folder Locker" in the right-click menu of folders and files.
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: ""; ValueData: "Lock with {#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\*\shell\{#LockVerb}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" --lock ""%1"""

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
  LogFile := ExpandConstant('{%TEMP}\FolderLocker-Dokany.log');
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
      'Dokany could not be installed (code ' + IntToStr(ResultCode) + ').' +
      #13#10 + #13#10 +
      'Everything else works. To open encrypted folders as drives, install ' +
      'Dokany later in {#AppName}: Settings, Encrypted drives.' + #13#10 +
      'Details: ' + LogFile,
      mbInformation, MB_OK, IDOK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('dokany') then
    InstallDokany;
end;

function NeedRestart(): Boolean;
begin
  Result := DokanyNeedsRestart;
end;
#endif

function InitializeUninstall(): Boolean;
begin
  Result := SuppressibleMsgBox(
    'Your data stays safe after {#AppName} is removed:' + #13#10 + #13#10 +
    '- Locked items stay encrypted. Install {#AppName} again to open them ' +
    'with your password or recovery key.' + #13#10 +
    '- Encrypted drives (.flkd folders) stay encrypted too.' + #13#10 +
    '- Blocked and read-only items stay protected. Unlock them first, or ' +
    'install {#AppName} again to unlock them.' + #13#10 +
    '- Unlocked items stay normal folders and files.' + #13#10 +
    '- Your settings in %APPDATA%\FolderLocker are kept.' + #13#10 +
    '- Dokany stays installed, as other apps may use it. You can remove it ' +
    'in Windows Settings, Apps.' + #13#10 + #13#10 +
    'Uninstall {#AppName} now?',
    mbConfirmation, MB_YESNO, IDYES) = IDYES;
end;

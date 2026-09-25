<#
Builds the Microsoft Store package (see AppxManifest.xml) from the app as
Setup ships it: the built app with the drive helper and the Explorer
plug-in next to it, without Dokany's installer.

The Store signs the package when it's uploaded, so it needs no certificate.
To install it anywhere else (like CI does to test it), sign it with a
certificate whose subject is the publisher, which that PC trusts.

The identity comes from Partner Center (Product identity), for example:

pwsh installer\msix\build-msix.ps1 -Source build\windows\x64\runner\Release `
    -Name 'PriyankRaychura.Cloak' -Publisher 'CN=00000000-0000-0000-0000-000000000000' `
    -PublisherDisplayName 'Priyank Raychura' -Version 1.3.9 -Destination build\msix

Writes Cloak-<version>.msix to the destination and outputs its path.
#>
param(
    # The built app (flutter build windows --release).
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Publisher,
    [Parameter(Mandatory)] [string] $PublisherDisplayName,
    # The app's version, like 1.3.9.
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Destination,
    [string] $Certificate,
    [string] $Password
)

$ErrorActionPreference = 'Stop'

function Find-SdkTool([string] $Name) {
    $tool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\$Name" |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1
    if (-not $tool) { throw "$Name was not found: install the Windows SDK" }
    $tool.FullName
}

# The app takes a package of this name for the Windows 11 menu package
# (lib/platform/app_package.dart), not for the Store version.
if ($Name -eq 'Cloak.ExplorerMenu') { throw "$Name is the Windows 11 menu package's name" }
foreach ($file in 'cloak.exe', 'cloak_drive.exe', 'cloak_shell.dll') {
    if (-not (Test-Path (Join-Path $Source $file))) { throw "$file is missing from $Source" }
}

New-Item -ItemType Directory -Force $Destination | Out-Null
# Full paths: .NET and the tools don't know PowerShell's current folder.
$Destination = (Resolve-Path $Destination).Path
$work = Join-Path $Destination 'package'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work | Out-Null

# The app, without Dokany's installer (a package can't install drivers).
Get-ChildItem $Source | Where-Object Name -ne 'dokany' |
    Copy-Item -Destination $work -Recurse
# The logos of the Windows 11 menu package, and the vault icon for .flk.
$assets = Join-Path $work 'Assets'
Copy-Item -Recurse (Join-Path $PSScriptRoot '..\sparse\Assets') $assets
Copy-Item (Join-Path $PSScriptRoot '..\..\assets\icons\vault_icon.png') (Join-Path $assets 'VaultLogo.png')

$escape = { param($text) [Security.SecurityElement]::Escape($text) }
$manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'AppxManifest.xml')
$manifest = $manifest.Replace('$NAME$', (& $escape $Name))
$manifest = $manifest.Replace('$PUBLISHER_DISPLAY_NAME$', (& $escape $PublisherDisplayName))
$manifest = $manifest.Replace('$PUBLISHER$', (& $escape $Publisher))
# The Store keeps the last part for itself: it must be 0, so every Store
# update needs a higher app version (pubspec.yaml), not just a new build.
$manifest = $manifest.Replace('$VERSION$', "$Version.0")
# UTF-8 without a byte order mark, in Windows PowerShell and PowerShell 7.
[IO.File]::WriteAllText((Join-Path $work 'AppxManifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))

# The tools' messages go to the console; only the package's path is output.
$package = Join-Path $Destination "Cloak-$Version.msix"
& (Find-SdkTool 'makeappx.exe') pack /d $work /p $package /o | Out-Host
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed ($LASTEXITCODE)" }

if ($Certificate) {
    & (Find-SdkTool 'signtool.exe') sign /fd SHA256 /f $Certificate /p $Password $package | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "SignTool failed ($LASTEXITCODE)" }
}
$package

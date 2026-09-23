<#
.SYNOPSIS
Builds the Windows 11 menu package (see AppxManifest.xml) and signs it.

.DESCRIPTION
Packs this folder's manifest and logos with MakeAppx from the Windows SDK,
fills in the publisher and version, and signs the package with SignTool
when a certificate is given. The publisher must be the certificate's
subject, exactly. Prints the package's path.

Install it for the current user next to the installed app with:

  Add-AppxPackage -Path <package> -ExternalLocation <app folder>

.EXAMPLE
pwsh installer\sparse\build-package.ps1 -Publisher 'CN=Folder Locker Test' -Version 1.2.0 -Destination build\sparse -Certificate test.pfx -Password test
#>
param(
    [Parameter(Mandatory)] [string] $Publisher,
    # The app's version, like 1.2.0.
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

New-Item -ItemType Directory -Force $Destination | Out-Null
$work = Join-Path $Destination 'package'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work | Out-Null
Copy-Item -Recurse (Join-Path $PSScriptRoot 'Assets') $work

$manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'AppxManifest.xml')
$manifest = $manifest.Replace('$PUBLISHER$', [Security.SecurityElement]::Escape($Publisher))
$manifest = $manifest.Replace('$VERSION$', "$Version.0")
Set-Content -Path (Join-Path $work 'AppxManifest.xml') -Value $manifest -Encoding utf8NoBOM

# The tools' messages go to the console; only the package's path is output.
# /nv: the app it points to isn't in the package.
$package = Join-Path (Resolve-Path $Destination) 'FolderLocker-ExplorerMenu.msix'
& (Find-SdkTool 'makeappx.exe') pack /d $work /p $package /nv /o | Out-Host
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed ($LASTEXITCODE)" }

if ($Certificate) {
    & (Find-SdkTool 'signtool.exe') sign /fd SHA256 /f $Certificate /p $Password $package | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "SignTool failed ($LASTEXITCODE)" }
}
$package

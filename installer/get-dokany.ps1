# Downloads the Dokany installer that Cloak ships and tests with,
# and checks that it is exactly the expected file.
#
#   pwsh installer\get-dokany.ps1 -Destination build\windows\x64\runner\Release\dokany
#
# Prints the path of Dokan_x64.msi. CI uses it for the installer and for the
# drive tests, so both use the same Dokany. To move to a newer Dokany, change
# the version and the SHA-256 below (the winget manifest of
# dokan-dev.Dokany lists it), and let CI run the drive tests with it.

param(
    [Parameter(Mandatory = $true)]
    [string] $Destination
)

$ErrorActionPreference = 'Stop'

$version = '2.3.1.1000'
$sha256 = '69FF8CB37BFEC3A75921C85FFD1C6370B50A9EC4ECEF2CF3A009D488DCBF5465'
$url = "https://github.com/dokan-dev/dokany/releases/download/v$version/Dokan_x64.msi"

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$msi = Join-Path (Resolve-Path $Destination) 'Dokan_x64.msi'

function Get-Sha256([string] $path) {
    (Get-FileHash -Path $path -Algorithm SHA256).Hash
}

if (-not (Test-Path $msi) -or (Get-Sha256 $msi) -ne $sha256) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $msi
}

$actual = Get-Sha256 $msi
if ($actual -ne $sha256) {
    Remove-Item $msi
    throw "Dokan_x64.msi $version has the SHA-256 $actual, expected $sha256"
}

$msi

<#
.SYNOPSIS
Installs the development add-on by linking this checkout into a WoW client.

.DESCRIPTION
Creates the junction Interface\AddOns\AsgardsGuildFellowshipDev pointing at
this checkout, after fetching the pinned libraries into Libs\. Safe to run
repeatedly. It never replaces a real folder or a junction that points
somewhere else, never edits repository files, and never changes permissions.
Windows only.

.EXAMPLE
./tools/Install-Dev.ps1

.EXAMPLE
./tools/Install-Dev.ps1 -Client Retail -WowInstallRoot "D:\World of Warcraft"
#>
[CmdletBinding()]
param(
    # Which supported client to link into. Forever stays the default.
    [ValidateSet("Forever", "Retail")]
    [string]$Client = "Forever",

    # The "World of Warcraft" folder that contains each client's directory.
    [string]$WowInstallRoot,

    # A specific client directory; overrides the one derived from -Client.
    [string]$WowRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The folder name must equal the dev manifest base name, or WoW does not find
# the manifest through the junction.
$addonFolderName = "AsgardsGuildFellowshipDev"
$clients = @{
    Forever = @{ Directory = "_classic_beta_"; Manifest = "AsgardsGuildFellowshipDev_Camelot.toc" }
    Retail = @{ Directory = "_retail_"; Manifest = "AsgardsGuildFellowshipDev_Mainline.toc" }
}
$target = $clients[$Client]

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot $target.Manifest
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "$Client development manifest not found at '$manifestPath'. Run this script from the repository checkout."
}

if ([string]::IsNullOrWhiteSpace($WowRoot)) {
    if ([string]::IsNullOrWhiteSpace($WowInstallRoot)) {
        $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
        $WowInstallRoot = Join-Path $programFilesX86 "World of Warcraft"
    }
    $WowRoot = Join-Path $WowInstallRoot $target.Directory
}

if (-not (Test-Path -LiteralPath $WowRoot -PathType Container)) {
    throw "$Client client directory not found at '$WowRoot'. Pass -WowInstallRoot with your 'World of Warcraft' folder, or -WowRoot with the exact $Client client directory."
}
$resolvedWowRoot = Resolve-Path -LiteralPath $WowRoot
$addonsDirectory = Join-Path $resolvedWowRoot.Path "Interface\AddOns"
if (-not (Test-Path -LiteralPath $addonsDirectory -PathType Container)) {
    throw "WoW AddOns directory not found at '$addonsDirectory'. Pass -WowRoot with the correct $Client client directory."
}

$destination = Join-Path $addonsDirectory $addonFolderName
$trimSeparators = [char[]]"\/"
$repoPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd($trimSeparators)

# Check an existing folder before fetching, so a refusal changes nothing.
$alreadyLinked = $false
if (Test-Path -LiteralPath $destination) {
    $existing = Get-Item -LiteralPath $destination -Force
    $isLink = ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink) {
        throw "'$destination' already exists and is not a junction. It was not changed."
    }

    $targets = @($existing.Target | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targets.Count -ne 1) {
        throw "'$destination' is a junction with an unreadable target. It was not changed."
    }

    $existingTarget = [IO.Path]::GetFullPath($targets[0]).TrimEnd($trimSeparators)
    if (-not [string]::Equals(
        $existingTarget,
        $repoPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "'$destination' points to '$existingTarget', not '$repoPath'. It was not changed."
    }
    $alreadyLinked = $true
}

# The dev add-on must never load without its libraries.
$fetchScript = Join-Path $PSScriptRoot "Fetch-Libraries.ps1"
$global:LASTEXITCODE = 0
try {
    & $fetchScript
} catch {
    throw "Fetching libraries failed, so the add-on was not linked: $($_.Exception.Message)"
}
if ($LASTEXITCODE -ne 0) {
    throw "Fetching libraries failed (exit code $LASTEXITCODE), so the add-on was not linked. Fix the error above and run the installer again."
}

if ($alreadyLinked) {
    Write-Host "Development add-on is already linked for ${Client}:"
    Write-Host "  $destination -> $repoPath"
    return
}

New-Item -ItemType Junction -Path $destination -Target $repoPath | Out-Null
Write-Host "Development add-on linked for ${Client}:"
Write-Host "  $destination -> $repoPath"
Write-Host "Restart WoW so it discovers Asgard's Guild Fellowship (Dev)."

<#
.SYNOPSIS
Fetches the pinned third-party libraries into the git-ignored Libs folder.

.DESCRIPTION
Reads tools/libraries.txt and downloads each library at its pinned tag into
its target folder under Libs/, the paths the manifests load. git sources are
cloned at their tag; svn sources (CurseForge) are downloaded from their pinned
tag folder over HTTPS, so no svn client is needed.

The script is idempotent: a library whose recorded pin matches the list is
left alone, and one whose pin changed is fetched again. It writes only inside
Libs/, and it exits non-zero with a message naming the library on failure.
Works in Windows PowerShell 5.1 and in pwsh.

.EXAMPLE
./tools/Fetch-Libraries.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$listPath = Join-Path $PSScriptRoot 'libraries.txt'
$librariesRoot = Join-Path $repositoryRoot 'Libs'
$pinFileName = '.pin'

function Read-LibraryList {
    $columns = 'name', 'major', 'target', 'load', 'type', 'url', 'tag'
    $entries = @()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $listPath) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            continue
        }

        $fields = @($trimmed.Split('|') | ForEach-Object { $_.Trim() })
        if ($fields.Count -ne $columns.Count) {
            throw "libraries.txt line ${lineNumber}: expected $($columns.Count) columns, got $($fields.Count)."
        }

        $entry = [ordered]@{}
        for ($index = 0; $index -lt $columns.Count; $index++) {
            $entry[$columns[$index]] = $fields[$index]
        }
        $entries += [pscustomobject]$entry
    }
    return $entries
}

# The full path of a library's target, refusing anything outside Libs/.
function Resolve-LibraryTarget([pscustomobject] $Library) {
    if ($Library.target -notmatch '^Libs/[^/]' -or $Library.target.Contains('..')) {
        throw "$($Library.name): target '$($Library.target)' is not a folder under Libs/."
    }

    $relative = $Library.target.Substring('Libs/'.Length) -replace '/', [IO.Path]::DirectorySeparatorChar
    return Join-Path $librariesRoot $relative
}

function Get-PinText([pscustomobject] $Library) {
    return "$($Library.type) $($Library.url) $($Library.tag)"
}

# Downloads an svn directory listing (Apache mod_dav_svn HTML) recursively.
function Save-SvnFolder([string] $Url, [string] $Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $folderUrl = $Url.TrimEnd('/') + '/'
    $listing = Invoke-WebRequest -Uri $folderUrl -UseBasicParsing
    $links = [regex]::Matches($listing.Content, '<li><a href="([^"]+)">')
    foreach ($link in $links) {
        $href = $link.Groups[1].Value
        if ($href -eq '../' -or $href.StartsWith('/') -or $href.Contains('://') -or $href.Contains('..')) {
            continue
        }

        $name = [uri]::UnescapeDataString($href.TrimEnd('/'))
        $childPath = Join-Path $Destination $name
        if ($href.EndsWith('/')) {
            Save-SvnFolder -Url ($folderUrl + $href) -Destination $childPath
        } else {
            Invoke-WebRequest -Uri ($folderUrl + $href) -OutFile $childPath -UseBasicParsing
        }
    }
}

function Save-GitTag([string] $Url, [string] $Tag, [string] $Destination) {
    & git -c advice.detachedHead=false clone --quiet --depth 1 --branch $Tag $Url $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "git clone of $Url at $Tag failed (exit code $LASTEXITCODE)."
    }
    # Keep only the files; a nested repository would confuse the checkout.
    Remove-Item -LiteralPath (Join-Path $Destination '.git') -Recurse -Force
}

function Sync-Library([pscustomobject] $Library) {
    $target = Resolve-LibraryTarget $Library
    $pinPath = Join-Path $target $pinFileName
    $pin = Get-PinText $Library

    if ((Test-Path -LiteralPath $pinPath) -and ((Get-Content -LiteralPath $pinPath -Raw).Trim() -eq $pin)) {
        Write-Host "$($Library.name) $($Library.tag) is up to date."
        return
    }

    # Fetch into a staging folder first so a failure never leaves a broken
    # library behind; the old copy is replaced only after a full download.
    $staging = Join-Path $librariesRoot (".staging-" + (Split-Path -Leaf $target))
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }

    try {
        Write-Host "Fetching $($Library.name) $($Library.tag)..."
        if ($Library.type -eq 'git') {
            Save-GitTag -Url $Library.url -Tag $Library.tag -Destination $staging
        } elseif ($Library.type -eq 'svn') {
            Save-SvnFolder -Url $Library.url -Destination $staging
        } else {
            throw "unknown source type '$($Library.type)'."
        }

        if (-not (Test-Path -LiteralPath (Join-Path $staging $Library.load))) {
            throw "the download does not contain $($Library.load)."
        }

        Set-Content -LiteralPath (Join-Path $staging $pinFileName) -Value $pin -NoNewline
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Move-Item -LiteralPath $staging -Destination $target
    } catch {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
        throw "Could not fetch $($Library.name) $($Library.tag) from $($Library.url): $($_.Exception.Message)"
    }
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to fetch libraries. Install Git for Windows and try again.'
    }

    New-Item -ItemType Directory -Path $librariesRoot -Force | Out-Null
    $libraries = Read-LibraryList
    foreach ($library in $libraries) {
        Sync-Library $library
    }
    Write-Host "All $(@($libraries).Count) libraries are in $librariesRoot."
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

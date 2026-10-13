# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: GPL-3.0-only (as the project it is part of)
<#
.SYNOPSIS
    Builds the Cairn mod pack for Slime Rancher 2 (Ranching Together, SR2MP): release\Cairn-Pack-slime-rancher-2-<version>.zip and
    release\pack-index.json (what the Cairn launcher reads to see a newer pack exists).

.DESCRIPTION
    An *external* pack that goes into the game's own folder (docs in the launcher repository: docs/PACKS.md, installDir ".").
    The mod is built by the project's own service, against the game's assemblies it keeps behind a login, so the pack is made from the DLL the
    project publishes on its releases (SR2MP.dll), checked against a pinned sha256 by the release workflow.

      mod\ (the game's root)   MelonLoader (the x64 zip of its release, Apache-2.0): version.dll and the MelonLoader folder
      mod\Mods\SR2MP.dll       the mod
      pack.json      the contract with the launcher
      manifest.txt   MOD|<path>|<size>|<sha256>, one line per file

    NOT in the pack: Starlight, the library the mod needs. Its licence forbids bundling or hosting its DLL, so the player takes it from its
    author's page; the game's setup list (game.json) shows it as missing until Mods\Starlight.dll is there.

    The pack's version is the VERSION file (strict X.Y.Z, this project's own); the mod's version is the pack's "upstream".
    A file of the game's with the same name and other bytes is never overwritten by the launcher.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MelonLoaderZip,
    [Parameter(Mandatory)][string] $ModDll,
    [Parameter(Mandatory)][string] $UpstreamVersion
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "VERSION must be strict X.Y.Z, got '$version'" }
if ($UpstreamVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "upstream version must be X.Y.Z, got '$UpstreamVersion'" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$release = Join-Path $root 'release'
$stage = Join-Path $release 'pack-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$mod = Join-Path $stage 'mod'
New-Item -ItemType Directory -Force -Path (Join-Path $mod 'Mods') | Out-Null

$destFull = [IO.Path]::GetFullPath($mod).TrimEnd('\') + '\'
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $MelonLoaderZip))
try {
    foreach ($e in $zip.Entries) {
        $name = $e.FullName.Replace('\', '/')
        if ($name.EndsWith('/')) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $mod ($name -replace '/', '\')))
        if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "the archive has a path outside its folder: $($e.FullName)" }
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
    }
} finally { $zip.Dispose() }
Copy-Item $ModDll (Join-Path $mod 'Mods\SR2MP.dll')

foreach ($n in @('version.dll', 'MelonLoader\net6\MelonLoader.dll', 'Mods\SR2MP.dll')) {
    if (-not (Test-Path (Join-Path $mod $n))) { throw "the pack is missing $n" }
}
if (Test-Path (Join-Path $mod 'Mods\Starlight.dll')) { throw 'Starlight must not be in the pack (its licence forbids bundling it)' }

function Get-Sha256([string] $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$launcherMin = '0.3.22'
$packJson = [ordered]@{
    schema      = 2
    id          = 'slime-rancher-2'
    game        = 'slime-rancher-2'
    version     = $version
    upstream    = $UpstreamVersion
    kind        = 'external'
    installDir  = '.'
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $stage 'pack.json'), (($packJson | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $mod -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($mod.Length + 1)
    $lines.Add(('MOD|{0}|{1}|{2}' -f $rel, $f.Length, (Get-Sha256 $f.FullName)))
}
[IO.File]::WriteAllText((Join-Path $stage 'manifest.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$zipName = "Cairn-Pack-slime-rancher-2-$version.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$fs = [IO.File]::Open($zipPath, 'Create')
try {
    $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $z.Dispose() }
} finally { $fs.Dispose() }

$index = [ordered]@{
    schema      = 2
    id          = 'slime-rancher-2'
    game        = 'slime-rancher-2'
    version     = $version
    upstream    = $UpstreamVersion
    kind        = 'external'
    file        = $zipName
    sha256      = Get-Sha256 $zipPath
    size        = (Get-Item $zipPath).Length
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $release 'pack-index.json'), (($index | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "pack: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB), version $version, SR2MP $UpstreamVersion, $($lines.Count) files"

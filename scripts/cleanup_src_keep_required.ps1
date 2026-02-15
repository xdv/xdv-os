param(
    [string]$SrcDir = (Join-Path $PSScriptRoot "..\src"),
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseNorm = $Base.TrimEnd('\', '/') + '\'
    $baseUri = New-Object System.Uri($baseNorm)
    $pathUri = New-Object System.Uri($Path)
    $relUri = $baseUri.MakeRelativeUri($pathUri)
    return [System.Uri]::UnescapeDataString($relUri.ToString()).Replace('\', '/')
}

$resolvedSrc = (Resolve-Path -LiteralPath $SrcDir).Path
$srcLeaf = Split-Path -Path $resolvedSrc -Leaf
$xdvOsLeaf = Split-Path -Path (Split-Path -Path $resolvedSrc -Parent) -Leaf

if ($srcLeaf -ne "src" -or $xdvOsLeaf -ne "xdv-os") {
    throw "Safety check failed: SrcDir must be the xdv-os/src directory. Got: $resolvedSrc"
}

$keepRelative = @(
    "boot_sector.asm",
    "build.bat",
    "build.sh",
    "kernel_entry.ds"
)

$keepSet = @{}
foreach ($k in $keepRelative) {
    $keepSet[$k.ToLowerInvariant()] = $true
}

$allFiles = Get-ChildItem -LiteralPath $resolvedSrc -File -Recurse
$toDelete = @()

foreach ($file in $allFiles) {
    $rel = Get-RelativePath -Base $resolvedSrc -Path $file.FullName
    if (-not $keepSet.ContainsKey($rel.ToLowerInvariant())) {
        $toDelete += [PSCustomObject]@{
            RelativePath = $rel
            FullName = $file.FullName
            SizeBytes = $file.Length
        }
    }
}

$totalBytes = ($toDelete | Measure-Object -Property SizeBytes -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }

Write-Host "xdv-os/src cleanup plan"
Write-Host "  Source: $resolvedSrc"
Write-Host "  Keep : $($keepRelative -join ', ')"
Write-Host "  Delete candidates: $($toDelete.Count) file(s)"
Write-Host "  Delete size: $totalBytes bytes"
Write-Host ""

if ($toDelete.Count -gt 0) {
    $toDelete | Sort-Object RelativePath | ForEach-Object {
        Write-Host "DEL  $($_.RelativePath)"
    }
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Apply to perform deletion."
    exit 0
}

foreach ($item in $toDelete) {
    Remove-Item -LiteralPath $item.FullName -Force
}

# Remove empty directories left behind.
Get-ChildItem -LiteralPath $resolvedSrc -Directory -Recurse |
    Sort-Object FullName -Descending |
    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
    Remove-Item -Force

Write-Host ""
Write-Host "Cleanup complete."
Write-Host "Deleted $($toDelete.Count) file(s) from xdv-os/src."

param(
    [string]$XdvOsDir = (Join-Path $PSScriptRoot ".."),
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseNorm = $Base.TrimEnd('\', '/') + '\'
    $baseUri = New-Object System.Uri($baseNorm)
    $pathUri = New-Object System.Uri($Path)
    $relUri = $baseUri.MakeRelativeUri($pathUri)
    return [System.Uri]::UnescapeDataString($relUri.ToString()).Replace('\', '/')
}

function Add-UniquePath([hashtable]$Index, [string]$Path) {
    $normalized = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    if (-not $Index.ContainsKey($normalized)) {
        $Index[$normalized] = [System.IO.Path]::GetFullPath($Path)
    }
}

function Get-MeasureSum([object[]]$InputItems, [string]$PropertyName) {
    if ($null -eq $InputItems -or $InputItems.Count -eq 0) {
        return [int64]0
    }
    $measure = $InputItems | Measure-Object -Property $PropertyName -Sum
    if ($null -eq $measure) {
        return [int64]0
    }
    if ($measure.PSObject.Properties.Name -contains "Sum") {
        if ($null -eq $measure.Sum) {
            return [int64]0
        }
        return [int64]$measure.Sum
    }
    return [int64]0
}

$resolvedRoot = (Resolve-Path -LiteralPath $XdvOsDir).Path
if ((Split-Path -Path $resolvedRoot -Leaf) -ne "xdv-os") {
    throw "Safety check failed: XdvOsDir must point to the xdv-os directory. Got: $resolvedRoot"
}

$srcDir = Join-Path $resolvedRoot "src"
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    throw "Missing source directory: $srcDir"
}

$deleteIndex = @{}

# Generated artifacts produced by xdv-os build and VM validation flows.
$wildcardFilePatterns = @(
    "*.img",
    "*.vdi",
    "*.png"
)

$exactFileNames = @(
    "boot_sector.bin",
    "boot.bin",
    "kernel.bin"
)

foreach ($pattern in $wildcardFilePatterns) {
    Get-ChildItem -LiteralPath $srcDir -File -Recurse -Filter $pattern | ForEach-Object {
        Add-UniquePath -Index $deleteIndex -Path $_.FullName
    }
}

foreach ($name in $exactFileNames) {
    Get-ChildItem -LiteralPath $srcDir -File -Recurse -Filter $name | ForEach-Object {
        Add-UniquePath -Index $deleteIndex -Path $_.FullName
    }
}

$targetDir = Join-Path $srcDir "target"
if (Test-Path -LiteralPath $targetDir -PathType Container) {
    Add-UniquePath -Index $deleteIndex -Path $targetDir
}

$items = @()
foreach ($full in $deleteIndex.Values | Sort-Object) {
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $items += [PSCustomObject]@{
            Type = "File"
            FullName = $full
            RelativePath = Get-RelativePath -Base $resolvedRoot -Path $full
            SizeBytes = (Get-Item -LiteralPath $full).Length
        }
    } elseif (Test-Path -LiteralPath $full -PathType Container) {
        $dirFiles = @(Get-ChildItem -LiteralPath $full -File -Recurse)
        $dirSize = Get-MeasureSum -InputItems $dirFiles -PropertyName "Length"
        $items += [PSCustomObject]@{
            Type = "Dir"
            FullName = $full
            RelativePath = Get-RelativePath -Base $resolvedRoot -Path $full
            SizeBytes = [int64]$dirSize
        }
    }
}

$totalBytes = Get-MeasureSum -InputItems $items -PropertyName "SizeBytes"

Write-Host "xdv-os cleanup plan"
Write-Host "  Root: $resolvedRoot"
Write-Host "  Source: $srcDir"
Write-Host "  Delete candidates: $($items.Count) item(s)"
Write-Host "  Delete size: $totalBytes bytes"
Write-Host ""

foreach ($item in $items) {
    Write-Host "DEL  [$($item.Type)] $($item.RelativePath)"
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Apply to delete listed artifacts."
    exit 0
}

foreach ($item in $items) {
    if (Test-Path -LiteralPath $item.FullName) {
        Remove-Item -LiteralPath $item.FullName -Force -Recurse
    }
}

Write-Host ""
Write-Host "Cleanup complete."
Write-Host "Deleted $($items.Count) item(s) from xdv-os."

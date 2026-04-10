param(
    [Parameter(Mandatory = $true)]
    [string]$RawImagePath,
    [Parameter(Mandatory = $true)]
    [string]$VdiPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-VBoxManage {
    $cmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    if ($env:ProgramFiles) {
        $candidate = Join-Path $env:ProgramFiles "Oracle\VirtualBox\VBoxManage.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-RegisteredVdiUuid([string]$VBoxManagePath, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $lines = & $VBoxManagePath showmediuminfo disk $Path 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*UUID:\s*([0-9A-Fa-f-]{36})\s*$') {
                return $Matches[1]
            }
        }
    } catch {
        return $null
    }

    return $null
}

if (-not (Test-Path -LiteralPath $RawImagePath)) {
    throw "Missing raw image: $RawImagePath"
}

$vboxManage = Resolve-VBoxManage
if (-not $vboxManage) {
    Write-Host "  VBoxManage not found; skipping VDI sync."
    exit 0
}

$resolvedRawImage = (Resolve-Path -LiteralPath $RawImagePath).Path
$resolvedVdi = [System.IO.Path]::GetFullPath($VdiPath)
$registeredUuid = Get-RegisteredVdiUuid -VBoxManagePath $vboxManage -Path $resolvedVdi

if (Test-Path -LiteralPath $resolvedVdi) {
    Remove-Item -LiteralPath $resolvedVdi -Force
}

$convertArgs = @("convertfromraw", $resolvedRawImage, $resolvedVdi, "--format", "VDI")
if ($registeredUuid) {
    $convertArgs += @("--uuid", $registeredUuid)
}

& $vboxManage @convertArgs
if ($LASTEXITCODE -ne 0) {
    throw "VBoxManage convertfromraw failed with exit code $LASTEXITCODE"
}

if ($registeredUuid) {
    Write-Host "  VDI updated: $resolvedVdi (UUID $registeredUuid)"
} else {
    Write-Host "  VDI updated: $resolvedVdi"
}

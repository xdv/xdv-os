param(
    [string]$ImagePath = (Join-Path $PSScriptRoot "..\src\xdv-os-mbr-64m.img"),
    [int]$BootTimeoutSec = 20,
    [int]$MemoryMB = 256,
    [string]$VmNamePrefix = "xdv-ci-boot",
    [string]$WorkDir = "",
    [switch]$KeepArtifacts
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

function Invoke-VBox([string]$VBoxManagePath, [string[]]$Args) {
    & $VBoxManagePath @Args
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage command failed ($LASTEXITCODE): $($Args -join ' ')"
    }
}

$vboxManage = Resolve-VBoxManage
if (-not $vboxManage) {
    throw "VBoxManage not found. VirtualBox profile test requires a VirtualBox-enabled runner."
}

if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Missing raw image: $ImagePath"
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $WorkDir = Join-Path $env:RUNNER_TEMP "xdv-vbox"
    } else {
        $WorkDir = Join-Path $PSScriptRoot "..\src\target\ci-vbox"
    }
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}

$stamp = (Get-Date).ToString("yyyyMMddHHmmss")
$rand = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$vmName = "$VmNamePrefix-$stamp-$rand"
$vdiPath = Join-Path $WorkDir "$vmName.vdi"
$serialLogPath = Join-Path $WorkDir "$vmName-serial.log"
$vmStarted = $false

Write-Host "[vbox] profile test image: $resolvedImage"
Write-Host "[vbox] vm name: $vmName"

try {
    Invoke-VBox $vboxManage @("convertfromraw", $resolvedImage, $vdiPath, "--format", "VDI")
    Invoke-VBox $vboxManage @("createvm", "--name", $vmName, "--ostype", "Other_64", "--basefolder", $WorkDir, "--register")

    Invoke-VBox $vboxManage @(
        "modifyvm", $vmName,
        "--firmware", "bios",
        "--memory", "$MemoryMB",
        "--vram", "16",
        "--ioapic", "on",
        "--rtcuseutc", "on",
        "--boot1", "disk",
        "--boot2", "none",
        "--boot3", "none",
        "--boot4", "none",
        "--audio", "none",
        "--usb", "off",
        "--nic1", "none"
    )

    Invoke-VBox $vboxManage @("modifyvm", $vmName, "--uart1", "0x03F8", "4", "--uartmode1", "file", $serialLogPath)
    Invoke-VBox $vboxManage @("storagectl", $vmName, "--name", "SATA", "--add", "sata", "--controller", "IntelAhci", "--hostiocache", "off")
    Invoke-VBox $vboxManage @("storageattach", $vmName, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", $vdiPath)
    Invoke-VBox $vboxManage @("startvm", $vmName, "--type", "headless")
    $vmStarted = $true

    Write-Host "[vbox] waiting $BootTimeoutSec second(s)"
    Start-Sleep -Seconds $BootTimeoutSec

    $vmInfo = & $vboxManage showvminfo $vmName --machinereadable
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query VM state"
    }

    $stateLine = $vmInfo | Where-Object { $_ -like 'VMState=*' } | Select-Object -First 1
    if (-not $stateLine) {
        throw "VM state missing from showvminfo output"
    }

    $vmState = $stateLine.Split("=")[1].Trim('"')
    if ($vmState -in @("aborted", "gurumeditation", "stuck")) {
        throw "VirtualBox boot test failed. VM state=$vmState"
    }

    $vmLogPath = Join-Path $WorkDir "$vmName\Logs\VBox.log"
    if (Test-Path -LiteralPath $vmLogPath) {
        $logText = Get-Content -LiteralPath $vmLogPath -Raw
        if ($logText -match "Guru Meditation|VINF_EM_TRIPLE_FAULT|Triple Fault|VMSetError") {
            throw "VirtualBox log indicates fatal boot error"
        }
    }

    Write-Host "[vbox] boot profile passed: state=$vmState"
}
finally {
    if ($vmStarted) {
        & $vboxManage controlvm $vmName poweroff *> $null
        Start-Sleep -Seconds 1
    }
    & $vboxManage unregistervm $vmName --delete *> $null

    if ((-not $KeepArtifacts) -and (Test-Path -LiteralPath $vdiPath)) {
        Remove-Item -LiteralPath $vdiPath -Force -ErrorAction SilentlyContinue
    }
    if ((-not $KeepArtifacts) -and (Test-Path -LiteralPath $serialLogPath)) {
        Remove-Item -LiteralPath $serialLogPath -Force -ErrorAction SilentlyContinue
    }
}

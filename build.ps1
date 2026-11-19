# 在有 Python 的电脑上打包。目标电脑只需要 Windows 自带的 PowerShell。
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$python = (Get-Command python -ErrorAction Stop).Source
& $python -m pip install pyinstaller pywin32
if ($LASTEXITCODE -ne 0) { throw '安装打包工具失败。' }

$work = Join-Path $env:TEMP 'door_ctrl_build'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item $work -ItemType Directory | Out-Null
Copy-Item tcp_server.py, tcp_service.py $work
Push-Location $work
try {
    & $python -m PyInstaller --noconfirm --clean --onedir --noconsole --name DoorCtrl `
        --hidden-import win32timezone `
        --hidden-import servicemanager `
        --hidden-import win32service `
        --hidden-import win32serviceutil `
        --hidden-import win32event `
        tcp_service.py
    if ($LASTEXITCODE -ne 0) { throw '打包失败。' }
    $built = Join-Path $work 'dist\DoorCtrl'
    $dest = Join-Path $PSScriptRoot 'dist'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item $dest -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $built '*') $dest -Recurse -Force
} finally {
    Pop-Location
}
foreach ($name in @('MiSwitch.ps1', 'config.json', 'service.ps1', 'test_switch.ps1')) {
    Copy-Item (Join-Path $PSScriptRoot $name) $dest -Force
}
if (Test-Path (Join-Path $PSScriptRoot 'lan.token')) {
    Copy-Item (Join-Path $PSScriptRoot 'lan.token') $dest -Force
}
Write-Output "已生成 $dest"
Write-Output '把 dist 整个目录拷到目标电脑。目标电脑不用安装 Python，安装时会提示为当前用户重新加密设备 Token。'

# 逐步测试查询、开、关。目标电脑不需要 Python。
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configPath = Join-Path $root 'config.json'
$port = 9753
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.listenPort) { $port = [int]$config.listenPort }
}
$targetHost = '127.0.0.1'
if ($args.Count -gt 0) { $targetHost = [string]$args[0] }
$tokenPath = Join-Path $root 'lan.token'
if (-not (Test-Path -LiteralPath $tokenPath)) { throw '找不到 lan.token。先启动巡检开关服务。' }
$token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
if (-not $token) { throw 'lan.token 是空的。' }

function Invoke-Switch([hashtable]$Fields) {
    $payload = @{ token = $token }
    foreach ($key in $Fields.Keys) { $payload[$key] = $Fields[$key] }
    $json = ($payload | ConvertTo-Json -Compress) + "`n"
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.ReceiveTimeout = 70000
        $client.SendTimeout = 70000
        $client.Connect($targetHost, $port)
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $line = $reader.ReadLine()
    } catch {
        throw "连不上 ${targetHost}:${port}。先确认巡检开关服务已启动。"
    } finally {
        $client.Close()
    }
    if (-not $line) { throw '服务没有返回' }
    $data = $line | ConvertFrom-Json
    $data | ConvertTo-Json -Depth 6 | Write-Output
    if ($data.switch -eq 'on') { Write-Output '开关 开' }
    elseif ($data.switch -eq 'off') { Write-Output '开关 关' }
    if ($data.ok -ne $true) { throw '这一步失败，已停止。' }
}

Write-Output "目标 ${targetHost}:${port}"
Write-Output '请先启动巡检开关服务。'
Invoke-Switch @{ cmd = 'status' }
Read-Host '下一步：打开开关。请看着开关。按回车发送'
Invoke-Switch @{ cmd = 'switch'; value = 'on' }
Read-Host '下一步：关闭开关。按回车发送'
Invoke-Switch @{ cmd = 'switch'; value = 'off' }
Invoke-Switch @{ cmd = 'status' }
Write-Output '查询、打开、关闭都已发送。'

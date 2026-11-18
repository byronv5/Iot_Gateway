# Compatible with Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param(
    [ValidateSet('Status','LeftOn','LeftOff','RightOn','RightOff','AllOff','Configure')]
    [string]$Action='Status',
    [string]$DeviceIP='192.168.1.41',
    [uint32]$DeviceID=305869963,
    [string]$CredentialPath,
    [Security.SecureString]$DeviceToken
)
$ErrorActionPreference='Stop'
if(!$CredentialPath){$CredentialPath=Join-Path $PSScriptRoot 'mi-switch.credential.xml'}
function ConvertTo-Hex([byte[]]$Bytes){return [BitConverter]::ToString($Bytes).Replace('-','')}
function ConvertFrom-Hex([string]$Text){
    if($Text -notmatch '^[0-9a-fA-F]{32}$'){throw 'Device Token must contain 32 hexadecimal characters.'}
    $bytes=New-Object byte[] 16
    for($i=0;$i-lt 16;$i++){$bytes[$i]=[Convert]::ToByte($Text.Substring($i*2,2),16)}
    return ,$bytes
}
if($Action-eq 'Configure'){
    if(!$DeviceToken){$DeviceToken=Read-Host 'Enter device Token (32 hexadecimal characters)' -AsSecureString}
    $credential=New-Object Management.Automation.PSCredential('miio-device',$DeviceToken)
    $null=ConvertFrom-Hex $credential.GetNetworkCredential().Password
    $credential|Export-Clixml -LiteralPath $CredentialPath -Encoding UTF8
    @{ok=$true;configured=$true;credentialPath=$CredentialPath}|ConvertTo-Json -Compress
    return
}
$target=$DeviceIP
$script:deviceDid=[string]$DeviceID
$script:seq=Get-Random -Minimum 8500 -Maximum 9000

function Get-MD5([byte[]]$Bytes) { $md5=[Security.Cryptography.MD5]::Create(); try { return ,$md5.ComputeHash($Bytes) } finally {$md5.Dispose()} }
function Get-BE32([byte[]]$Bytes,[int]$Offset) { return [uint32](([uint64]$Bytes[$Offset]*16777216)+([uint64]$Bytes[$Offset+1]*65536)+([uint64]$Bytes[$Offset+2]*256)+$Bytes[$Offset+3]) }
function Write-BE([IO.BinaryWriter]$Writer,[uint64]$Value,[int]$Size) { for($shift=($Size-1)*8;$shift-ge 0;$shift-=8) {$Writer.Write([byte](($Value-shr $shift)-band 255))} }
function Invoke-Miio([string]$Method,$Params) {
    $udp=[Net.Sockets.UdpClient]::new()
    $udp.EnableBroadcast=$true
    $udp.Client.ReceiveTimeout=500
    try {
        $hello=[byte[]](@(0x21,0x31,0,0x20)+(@(255)*28))
        $handshake=$null
        foreach($attempt in 1..3) {
            [void]$udp.Send($hello,32,$target,54321)
            try {
                $remote=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0)
                $candidate=$udp.Receive([ref]$remote)
                if($remote.Address.ToString()-eq $target -and $candidate.Length-eq 32) {$handshake=$candidate;break}
            } catch [Net.Sockets.SocketException] {}
        }
        if($null-eq $handshake) {throw 'Discovery timeout'}
        $did=Get-BE32 $handshake 8
        if([uint32]$did -ne [uint32]$script:deviceDid) {throw 'Device ID mismatch'}
        $stamp=Get-BE32 $handshake 12
        Start-Sleep -Milliseconds 1100
        $script:seq++
        $payload=[Text.Encoding]::UTF8.GetBytes((@{id=$script:seq;method=$Method;params=$Params}|ConvertTo-Json -Depth 10 -Compress)+[char]0)
        $key=Get-MD5 $token
        $iv=Get-MD5 ([byte[]]($key+$token))
        $aes=[Security.Cryptography.Aes]::Create()
        $aes.Key=$key; $aes.IV=$iv; $aes.Mode='CBC'; $aes.Padding='PKCS7'
        $enc=$aes.CreateEncryptor()
        try {$cipher=$enc.TransformFinalBlock($payload,0,$payload.Length)} finally {$enc.Dispose()}
        $stream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($stream)
        Write-BE $writer 0x2131 2; Write-BE $writer (32+$cipher.Length) 2; Write-BE $writer 0 4; Write-BE $writer $did 4; Write-BE $writer ($stamp+1) 4
        $header=$stream.ToArray();$writer.Dispose();$stream.Dispose()
        $checksum=Get-MD5 ([byte[]]($header+$token+$cipher))
        $packet=[byte[]]($header+$checksum+$cipher)
        $udp.Client.ReceiveTimeout=1500
        foreach($attempt in 1..2) {
            [void]$udp.Send($packet,$packet.Length,$target,54321)
            try {$remote=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$reply=$udp.Receive([ref]$remote)} catch [Net.Sockets.SocketException] {continue}
            if($remote.Address.ToString()-ne $target -or $reply.Length-le 32){continue}
            $expected=Get-MD5 ([byte[]]($reply[0..15]+$token+$reply[32..($reply.Length-1)]))
            if((ConvertTo-Hex $expected)-ne (ConvertTo-Hex ([byte[]]$reply[16..31]))) {throw 'Reply checksum mismatch'}
            $dec=$aes.CreateDecryptor()
            try {$plain=$dec.TransformFinalBlock($reply,32,$reply.Length-32)} finally {$dec.Dispose();$aes.Dispose()}
            return ([Text.Encoding]::UTF8.GetString($plain).TrimEnd([char]0)|ConvertFrom-Json)
        }
        throw 'Authenticated request timeout after successful discovery'
    } finally {$udp.Dispose()}
}

function Read-State {
    $params=@(@{did=$script:deviceDid;siid=2;piid=1},@{did=$script:deviceDid;siid=3;piid=1},@{did=$script:deviceDid;siid=5;piid=5})
    $response=Invoke-Miio 'get_properties' $params
    if($response.error){throw ($response.error|ConvertTo-Json -Compress)}
    $values=@{}
    foreach($entry in $response.result){
        if($entry.code-ne 0 -or $entry.value-isnot [bool]){throw 'State could not be read.'}
        $values[[int]$entry.siid]=[bool]$entry.value
    }
    if($values.Count-ne 3){throw 'Incomplete state response.'}
    return @{left=$values[2];right=$values[3];interlock=$values[5]}
}
function Write-Result($Value) {
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Value -Depth 6 -Compress))
    [Console]::Out.Flush()
}
function Get-CredentialGuide {
    return "当前 Windows 用户解不开设备密钥。请用这个用户打开管理员 PowerShell，进入 $PSScriptRoot 后执行 service.ps1 Install，按提示输入原来的 32 位设备 Token。"
}
function Test-CredentialLock($Exception) {
    $current=$Exception
    while($current){
        if($current -is [Security.Cryptography.CryptographicException]){return $true}
        $text=[string]$current.Message
        if($text -match 'Key not valid for use in specified state' -or $text -match '指定状态'){return $true}
        $current=$current.InnerException
    }
    return $false
}
function Invoke-SwitchAction([string]$Action) {
try {
    if(!(Test-Path -LiteralPath $CredentialPath)){
        Write-Result @{ok=$false;action=$Action;needConfigure=$true;error=(Get-CredentialGuide)}
        return 1
    }
    try{
        $credential=Import-Clixml -LiteralPath $CredentialPath
        $token=ConvertFrom-Hex $credential.GetNetworkCredential().Password
    }catch{
        if(-not (Test-CredentialLock $_.Exception)){throw}
        Write-Result @{ok=$false;action=$Action;needConfigure=$true;error=(Get-CredentialGuide)}
        return 1
    }
    $credential=$null
    if($Action-eq 'Status'){
        $state=$null
        foreach($attempt in 1..3){try{$state=Read-State;break}catch{if($attempt-eq 3){throw}}}
        Write-Result @{ok=$true;ip=$target;state=$state}
        return 0
    }
    $desired=@{}
    switch($Action){
        'LeftOn'   {$desired[2]=$true}
        'LeftOff'  {$desired[2]=$false}
        'RightOn'  {$desired[3]=$true}
        'RightOff' {$desired[3]=$false}
        'AllOff'   {$desired[2]=$false;$desired[3]=$false}
    }
    $params=@(foreach($side in @(2,3)){if($desired.ContainsKey($side)){@{did=$script:deviceDid;siid=$side;piid=1;value=$desired[$side]}}})
    $ack=$null
    try{
        $ack=Invoke-Miio 'set_properties' $params
        if($ack.error -or !$ack.result -or @($ack.result|Where-Object {$_.code-ne 0}).Count-gt 0){throw 'Device rejected the command.'}
    }catch{
        # A lost acknowledgement does not mean that the write failed.
        # Verify state before deciding the result.
        $writeError=$_.Exception.Message
    }
    Start-Sleep -Milliseconds 2500
    $verified=$false;$state=$null
    foreach($attempt in 1..3){
        try{
            $state=Read-State
            $verified=$true
            foreach($side in $desired.Keys){$name=if($side-eq 2){'left'}else{'right'};if($state[$name]-ne $desired[$side]){$verified=$false}}
            if($verified){break}
        }catch{$readError=$_.Exception.Message}
        Start-Sleep -Milliseconds 1000
    }
    if(!$verified){
        Write-Result @{ok=$false;action=$Action;state=$state;error='Target state unconfirmed. Check Status or Mi Home before retrying.';writeError=$writeError;readError=$readError}
        return 2
    }
    Write-Result @{ok=$true;action=$Action;ip=$target;state=$state}
    return 0
}catch{
    Write-Result @{ok=$false;action=$Action;error=$_.Exception.Message}
    return 1
}finally{if($token){[Array]::Clear($token,0,$token.Length)}}
}
if($MyInvocation.InvocationName -ne '.'){exit (Invoke-SwitchAction $Action)}

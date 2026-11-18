# 安装、卸载、启动、停止巡检开关 Windows 服务。需要管理员权限。目标电脑不用安装 Python。
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('Install','Uninstall','Start','Stop')]
    [string]$Command='Install'
)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw '请用管理员 PowerShell 运行。'
}
$exe=Join-Path $PSScriptRoot 'DoorCtrl.exe'
if(-not (Test-Path -LiteralPath $exe)){
    throw '找不到 DoorCtrl.exe。请在有 Python 的电脑上执行 build.ps1，再把生成的 dist\DoorCtrl 整个目录拷到这台电脑。'
}

function Test-DoorCtrlService {
    & sc.exe query DoorCtrl | Out-Null
    return $LASTEXITCODE -eq 0
}

function Unregister-DoorCtrlService {
    if(-not (Test-DoorCtrlService)){return}
    & sc.exe stop DoorCtrl | Out-Null
    $output=& sc.exe delete DoorCtrl | Out-String
    if($LASTEXITCODE -ne 0){throw "删除已有服务失败，退出码 $LASTEXITCODE。$($output.Trim())"}
    $deadline=(Get-Date).AddSeconds(15)
    do{
        if(-not (Test-DoorCtrlService)){return}
        Start-Sleep -Milliseconds 400
    }while((Get-Date) -lt $deadline)
    throw '旧服务尚未删除完成，请稍后再执行 service.ps1 Install。'
}

function Test-DeviceCredential {
    $path=Join-Path $PSScriptRoot 'mi-switch.credential.xml'
    if(-not (Test-Path -LiteralPath $path)){return $false}
    try{
        $credential=Import-Clixml -LiteralPath $path
        $password=$credential.GetNetworkCredential().Password
        return $password -match '^[0-9a-fA-F]{32}$'
    }catch{
        return $false
    }
}

function Grant-ServiceLogonRight([string]$Account) {
    if(-not ('DoorCtrlLogonRight' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class DoorCtrlLogonRight {
    [StructLayout(LayoutKind.Sequential)]
    struct LsaUnicodeString {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct LsaObjectAttributes {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }
    [DllImport("advapi32.dll")]
    static extern uint LsaOpenPolicy(IntPtr system, ref LsaObjectAttributes attributes, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern uint LsaAddAccountRights(IntPtr handle, IntPtr sid, LsaUnicodeString[] rights, uint count);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern int LsaNtStatusToWinError(uint status);
    public static void Grant(string account) {
        var sid = (SecurityIdentifier)new NTAccount(account).Translate(typeof(SecurityIdentifier));
        byte[] bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        IntPtr sidPtr = Marshal.AllocHGlobal(bytes.Length);
        var attributes = new LsaObjectAttributes();
        attributes.Length = Marshal.SizeOf(typeof(LsaObjectAttributes));
        IntPtr handle;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x00000811, out handle);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        try {
            Marshal.Copy(bytes, 0, sidPtr, bytes.Length);
            string name = "SeServiceLogonRight";
            var rights = new LsaUnicodeString[1];
            rights[0].Buffer = Marshal.StringToHGlobalUni(name);
            rights[0].Length = (ushort)(name.Length * 2);
            rights[0].MaximumLength = (ushort)((name.Length + 1) * 2);
            try {
                status = LsaAddAccountRights(handle, sidPtr, rights, 1);
                if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            } finally {
                Marshal.FreeHGlobal(rights[0].Buffer);
            }
        } finally {
            LsaClose(handle);
            Marshal.FreeHGlobal(sidPtr);
        }
    }
}
'@
    }
    [DoorCtrlLogonRight]::Grant($Account)
}

function Protect-DeviceCredential {
    if(Test-DeviceCredential){return}
    Write-Output '当前 Windows 用户解不开设备密钥。请输入原来的 32 位设备 Token，程序会用这个用户重新加密。换电脑不需要更换 Token。'
    $token=Read-Host '设备 Token' -AsSecureString
    & (Join-Path $PSScriptRoot 'MiSwitch.ps1') -Action Configure -DeviceToken $token
}

switch($Command){
    'Install'{
        Protect-DeviceCredential
        $account="$env:USERDOMAIN\$env:USERNAME"
        Write-Output "设备密钥属于当前用户 $account，服务也使用这个用户运行。"
        $secure=Read-Host "输入 $account 的 Windows 密码" -AsSecureString
        $logon=New-Object Management.Automation.PSCredential($account,$secure)
        Grant-ServiceLogonRight $account
        Unregister-DoorCtrlService
        New-Service -Name DoorCtrl -BinaryPathName "`"$exe`"" -DisplayName '巡检开关服务' -Description '局域网 TCP 开关服务' -StartupType Automatic -Credential $logon | Out-Null
        Start-Service -Name DoorCtrl
        Write-Output '已安装并启动。换网络时先改 config.json 的 deviceIp、deviceId，再执行 service.ps1 Stop，然后 service.ps1 Start。'
    }
    'Uninstall'{
        Unregister-DoorCtrlService
        Write-Output '已卸载。'
    }
    'Start'{Start-Service -Name DoorCtrl}
    'Stop'{Stop-Service -Name DoorCtrl -Force}
}

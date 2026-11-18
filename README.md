米家开关局域网 TCP 服务

设备：babai.switch.202s。当前示例地址见 `config.json`：IP `192.168.1.41`，设备编号 `305869963`。

`tcp_server.py` 监听局域网 TCP。同一 WiFi 里的设备连这台电脑的 IP 加端口即可控制开关。服务内部通过 UDP 54321 和开关通信。不要同时发多条命令。

# 一. 部署

目标电脑不用安装 Python。在一台已经装了 Python 的电脑上进入本目录，执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

完成后把 `dist\DoorCtrl` 整个目录拷到目标电脑。这个目录里有 `DoorCtrl.exe`、`MiSwitch.ps1`、`config.json`、`service.ps1`。后面的步骤都在该目录进行。设备密钥文件不会打进这个目录。

用准备运行服务的那个 Windows 用户登录，再打开管理员 PowerShell。

1. 按现场修改 `config.json`。换网络改 `deviceIp`。换一台开关时再改 `deviceId`。`listenHost` 用 `0.0.0.0` 才能让局域网访问，`listenPort` 默认 `9753`。

```json
{
  "deviceIp": "192.168.1.41",
  "deviceId": 305869963,
  "listenHost": "0.0.0.0",
  "listenPort": 9753
}
```

2. 放行 TCP 端口，范围限制在开关所在网段。端口或网段不同时，改下面命令里的数字。

```powershell
netsh advfirewall firewall add rule name="MiSwitch TCP" dir=in action=allow protocol=TCP localport=9753 remoteip=192.168.1.0/24
```

3. 用管理员 PowerShell 安装并启动 Windows 服务。服务名是 `DoorCtrl`，显示名为「巡检开关服务」，开机自启。

安装时如果这台电脑解不开设备密钥，会要求输入原来的 32 位设备 Token。输入时屏幕不显示字符。不要用 `.s2` 或 `.s3` 子设备的 Token。Token 不随换电脑变化，只是在当前 Windows 用户下重新加密。服务固定用这个当前用户运行，接着会要求输入该用户的 Windows 密码，并授予该用户「以服务身份登录」。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Install
```

4. 确认开关动作。先等服务起来，再在本机执行。每一步按回车才发送：查询、打开、关闭。这一步只用 Windows 自带的 PowerShell。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_switch.ps1
```

从局域网另一台电脑测试时，加上这台电脑的 IP，并且那边要有同一份 `lan.token`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_switch.ps1 192.168.1.10
```

`lan.token` 是局域网调用口令。格式见 `lan.token.example`。生成方式见 1.4。

## 1.1 换网络

同一台电脑、同一个 Windows 用户，只改 `config.json` 的 `deviceIp`，然后重启服务。不用重新加密。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Start
```

## 1.2 解密失败

接口返回 `needConfigure` 为 `true` 时，用运行服务的那个 Windows 用户打开管理员 PowerShell，再执行一次 `service.ps1 Install`。安装程序发现解不开密钥后，会要求输入原来的 32 位设备 Token 并重新加密。

## 1.3 服务管理

以下命令都要在管理员 PowerShell 里、`DoorCtrl.exe` 所在目录执行。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Uninstall
```

不安装 Windows 服务时，可以在前台运行 `.\DoorCtrl.exe run`。开发机上也可以直接 `python .\tcp_server.py`。改过 `config.json` 或重新加密设备密钥之后，要停掉再启动。

## 1.4 密钥文件

仓库里只有示例，没有可用密钥。

| 示例 | 正式文件 | 作用 |
| --- | --- | --- |
| `lan.token.example` | `lan.token` | 第三方调用口令，文件里只有一行 |
| `mi-switch.credential.xml.example` | `mi-switch.credential.xml` | 设备 Token 的加密结果 |

`lan.token` 可以按示例自己写一行。服务目录里没有这个文件时，第一次启动会自动生成。

`mi-switch.credential.xml` 不能照抄示例。示例里的 `Password` 不是密钥。正式文件要在目标电脑上，用准备运行服务的那个 Windows 用户，把 32 位设备 Token 加密出来：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MiSwitch.ps1 -Action Configure
```

提示 `Enter device Token (32 hexadecimal characters):` 时输入 Token。屏幕不显示字符。脚本确认它是 32 位十六进制后，用当前 Windows 用户加密，并写出同目录的 `mi-switch.credential.xml`。用户名固定为 `miio-device`。

Token 来自绑定这台开关的米家账号，不要用 `.s2` 或 `.s3` 子设备的 Token。换电脑或换 Windows 用户后，用同一个 Token 再执行一次上面的命令。`service.ps1 Install` 发现没有密钥或解不开时，也会要求输入这个 Token 并完成同样的加密。

# 二. 对接

## 2.1 连接

第三方应用连接运行本服务的电脑。地址用这台电脑的局域网 IP，端口用 `config.json` 里的 `listenPort`，默认 `9753`。

协议是 TCP，编码是 UTF-8。一次连接只处理一条命令：发送一行紧凑 JSON，末尾必须是换行 `\n`，读回一行 JSON 后关闭连接。JSON 不要格式化成多行。单行请求不超过 4096 字节。客户端超时不少于 60 秒。开关动作通常约 2 秒。

服务同时只执行一条命令。收到上一条响应之后，再发送下一条。

`token` 取服务目录 `lan.token` 里的那一行，不要带换行，区分大小写。它是调用口令，与设备 Token 无关。

调用方只使用开和关。`value` 必须是字符串 `on` 或 `off`。

## 2.2 查询

```json
{"token":"口令","cmd":"status"}
```

成功：

```json
{"ok":true,"ip":"192.168.1.41","switch":"on","exitCode":0}
```

## 2.3 打开

```json
{"token":"口令","cmd":"switch","value":"on"}
```

成功：

```json
{"ok":true,"action":"on","ip":"192.168.1.41","switch":"on","exitCode":0}
```

## 2.4 关闭

```json
{"token":"口令","cmd":"switch","value":"off"}
```

成功：

```json
{"ok":true,"action":"off","ip":"192.168.1.41","switch":"off","exitCode":0}
```

## 2.5 响应字段

| 字段 | 含义 |
| --- | --- |
| `ok` | `true` 表示本条命令成功 |
| `switch` | `on` 开，`off` 关，`unknown` 表示设备没有报出明确状态 |
| `action` | 开关命令返回 `on` 或 `off`。查询命令不返回此字段 |
| `ip` | 开关 IP |
| `exitCode` | `0` 已成功并读回确认；`1` 出错；`2` 写入后未能确认目标状态 |
| `error` | 失败原因 |
| `needConfigure` | 为 `true` 时，服务电脑上的设备密钥无法解密 |

`switch` 是设备上报的状态。

## 2.6 调用步骤

1. 连接服务电脑的 IP 和端口。
2. 发送一行 JSON，以 `\n` 结束。
3. 读取一行响应。
4. 关闭连接。

10 秒内没有发完这一行，服务会断开，且不返回 JSON。

## 2.7 失败

口令、命令或参数不合法时没有 `exitCode`：

```json
{"ok":false,"error":"口令错误"}
```

`error` 还可能是：`请求不是 JSON`、`请求必须是 JSON 对象`、`cmd 只能是 status 或 switch`、`switch 的 value 只能是 on 或 off`。

命令超时：

```json
{"ok":false,"error":"设备命令超时。设备可能已经执行，先查询 status 再决定是否重试"}
```

超时或 `exitCode` 为 `2` 时，先发 `status`，再决定是否重试。

`needConfigure` 为 `true` 时，重试无效。由服务电脑的管理员重新执行 `service.ps1 Install`，并输入原来的 32 位设备 Token。

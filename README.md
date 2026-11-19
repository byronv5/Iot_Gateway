# 电动侧翻门局域网控制网关

本项目运行在 Windows 电脑上，作为**电动侧翻门（米家智能开关 `babai.switch.202s`）的局域网控制网关**。

- **对内**：通过局域网 UDP `54321` 端口与米家开关通信。
- **对外**：提供局域网 TCP 接口（默认端口 `9753`），同一局域网内的其他程序（如巡检机器人、上位机）发送 JSON 指令即可控制门的开关与状态查询。

> **先分清两个容易混淆的 Token：**
> 1. **设备 Token（32 位十六进制）**：米家开关硬件自身的密钥，用于电脑控制开关，会被加密存放在 `mi-switch.credential.xml` 中。
> 2. **`lan.token`（接口调用口令）**：本网关 TCP 接口自身的鉴权口令。第三方程序调用 TCP 接口时，必须在请求参数的 `"token"` 字段中填写 `lan.token` 文件里的内容。

---

## 一、快速上手部署（按步骤操作）

### 第 1 步：安装硬件并连入局域网 WiFi

1. 将电动侧翻门的米家开关（`babai.switch.202s`）完成物理安装并通电。
2. 用手机「米家 App」将开关配网，连接到**与网关电脑相同的局域网 WiFi**。

### 第 2 步：获取开关的 3 项信息

在路由器后台或米家工具（如小米 Token 提取工具）中获取该开关的以下信息，记录备用：

- **设备 IP**（如 `192.168.1.41`，建议在路由器中为其绑定静态 IP，防止重启后变动）
- **设备编号 `deviceId`**（纯数字，如 `305869963`）
- **设备 Token**（32 位十六进制字符串，如 `0123456789abcdef0123456789abcdef`）

> 注意：请使用主开关设备的 Token，**不要**使用 `.s2` 或 `.s3` 子设备的 Token。

### 第 3 步：准备运行程序

**情况 A：直接在当前电脑运行（已有 Python 环境）**  
可以直接跳过打包，使用源码目录操作。

**情况 B：部署到没有 Python 的目标电脑（推荐）**  
先在有 Python 的电脑上进入本项目目录，执行打包脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

打包完成后，将生成的 `dist` **整个文件夹**拷贝到目标电脑即可。目标电脑无需安装 Python。

> 以下第 4～7 步均在部署目录（如 `dist`）中，使用**准备运行服务的 Windows 账号**登录并打开**管理员 PowerShell** 执行。

### 第 4 步：修改配置文件 `config.json`

用记事本打开 `config.json`，填入第 2 步获取的设备 IP 和设备编号：

```json
{
  "deviceIp": "192.168.1.41",
  "deviceId": 305869963,
  "listenHost": "0.0.0.0",
  "listenPort": 9753,
  "openDelaySeconds": 6
}
```

- `deviceIp`：开关的局域网 IP。
- `deviceId`：开关的设备编号。
- `listenHost`：保持 `0.0.0.0`，允许局域网内其他机器访问。
- `listenPort`：TCP 监听端口，默认 `9753`。
- `openDelaySeconds`：打开指令（`value: "on"`）确认开关开启后的额外延迟响应时间（秒），默认 `6`，用于等待电动门完全开启到位；设为 `0` 则不延迟。

### 第 5 步：用设备 Token 生成 `mi-switch.credential.xml`

执行以下命令，把 32 位设备 Token 加密保存到当前目录的 `mi-switch.credential.xml`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MiSwitch.ps1 -Action Configure
```

按提示输入第 2 步获取的 **32 位十六进制设备 Token**（输入时屏幕不显示字符，粘贴或输入后直接回车）。看到输出 `configured: true` 即成功。

> 说明：`mi-switch.credential.xml` 与**当前电脑的当前 Windows 用户**绑定，不能从别的电脑直接复制过来使用（仓库中的 `.example` 仅为格式示例）。换电脑或换用户时，重新执行上面命令即可。

### 第 6 步：放行防火墙端口并启动服务

1. **放行 TCP 端口**（按实际端口和局域网网段修改）：

```powershell
netsh advfirewall firewall add rule name="MiSwitch TCP" dir=in action=allow protocol=TCP localport=9753 remoteip=192.168.1.0/24
```

2. **安装并启动 Windows 服务**（开机自启，服务名 `DoorCtrl`）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Install
```

- 如果第 5 步没做或密钥解不开，安装脚本会自动提示输入 32 位设备 Token 并生成 `mi-switch.credential.xml`。
- 接着按提示输入**当前 Windows 用户的登录密码**（用于让服务以当前用户身份运行，才能解密设备密钥）。

> **不想装服务、只想临时调试？**  
> 打包版可直接前台运行 `.\DoorCtrl.exe run`；源码版可直接运行 `python .\tcp_server.py`。

### 第 7 步：配置接口鉴权口令 `lan.token`

- 服务首次启动时，如果目录里没有 `lan.token`，会**自动生成**一个随机口令文件。
- 你也可以手动新建 `lan.token`（参考 `lan.token.example`），在里面写一行自定义字符串作为口令（不要有多余空行）。
- 后续任何调用方请求 TCP 接口时，都需要把 `lan.token` 里的这行内容填到请求的 `token` 参数中。

---

## 二、测试开关效果

服务启动后，在部署目录运行测试脚本（仅使用 Windows 自带 PowerShell，无需 Python）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_switch.ps1
```

脚本会自动读取当前目录的 `lan.token`，并按步骤引导你测试：
1. 自动查询当前开关状态；
2. 按回车发送**打开**指令（观察门/开关动作）；
3. 按回车发送**关闭**指令（观察门/开关动作）；
4. 再次查询状态确认。

**从局域网另一台电脑测试**：将 `test_switch.ps1` 和同一份 `lan.token` 放到另一台电脑的同一目录下，传入网关电脑的 IP 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_switch.ps1 192.168.1.10
```

---

## 三、TCP 接口对接文档

### 3.1 通信约定

- **地址**：网关电脑的局域网 IP + `config.json` 中的 `listenPort`（默认 `9753`）。
- **协议**：TCP 短连接，UTF-8 编码。
- **格式**：每次连接发送**一行紧凑 JSON**（不可换行格式化），末尾必须带换行符 `\n`，单行不超过 4096 字节。读取一行 JSON 响应后关闭连接。
- **超时与并发**：
  - 建立连接后 10 秒内未发完请求会被服务端断开。
  - 客户端读取超时建议 **≥ 60 秒**（正常开关动作约 2 秒）。
  - 服务端**串行执行**，请等待上一条指令返回后再发下一条。
- **鉴权**：请求中的 `token` 必须与网关目录 `lan.token` 文件中的内容完全一致（区分大小写，不含换行）。

### 3.2 请求与响应示例

#### 1. 查询状态

请求：
```json
{"token":"你的lan.token内容","cmd":"status"}
```

成功响应：
```json
{"ok":true,"ip":"192.168.1.41","switch":"on","exitCode":0}
```

#### 2. 打开

请求：
```json
{"token":"你的lan.token内容","cmd":"switch","value":"on"}
```

成功响应：
```json
{"ok":true,"action":"on","ip":"192.168.1.41","switch":"on","exitCode":0}
```

#### 3. 关闭

请求：
```json
{"token":"你的lan.token内容","cmd":"switch","value":"off"}
```

成功响应：
```json
{"ok":true,"action":"off","ip":"192.168.1.41","switch":"off","exitCode":0}
```

### 3.3 响应字段说明

| 字段 | 含义 |
| --- | --- |
| `ok` | `true` 表示成功，`false` 表示失败 |
| `switch` | 设备上报状态：`on`（开）、`off`（关）、`unknown`（未知） |
| `action` | 开关指令返回 `on` 或 `off`，查询指令无此字段 |
| `ip` | 开关设备的局域网 IP |
| `exitCode` | `0` 成功并已读回确认；`1` 出错；`2` 指令已发但未能确认目标状态 |
| `error` | 失败原因（仅失败时返回） |
| `needConfigure` | 为 `true` 时表示网关无法解密 `mi-switch.credential.xml`，需重新配置 |

### 3.4 常见错误响应

- 参数或口令错误（无 `exitCode`）：
  ```json
  {"ok":false,"error":"口令错误"}
  ```
  其他可能值：`请求不是 JSON`、`请求必须是 JSON 对象`、`cmd 只能是 status 或 switch`、`switch 的 value 只能是 on 或 off`。

- 设备超时或 `exitCode` 为 `2`：
  ```json
  {"ok":false,"error":"设备命令超时。设备可能已经执行，先查询 status 再决定是否重试"}
  ```
  处理建议：先发一次 `status` 确认实际状态，再决定是否重试。

---

## 四、日常运维与常见问题

### 常用服务管理命令

以下均需在管理员 PowerShell 中进入部署目录执行：

```powershell
# 停止服务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Stop

# 启动服务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Start

# 卸载服务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 Uninstall
```

### 更换 WiFi 或开关 IP 变化

只需修改 `config.json` 中的 `deviceIp`（如果换了新开关，同步修改 `deviceId` 并重新执行第 5 步），然后重启服务（先 `Stop` 再 `Start`），无需重新安装服务。

### 接口返回 `needConfigure: true`

说明当前运行服务的 Windows 用户无法解密 `mi-switch.credential.xml`。用该 Windows 用户打开管理员 PowerShell，重新执行 `service.ps1 Install`，按提示重新输入原来的 32 位设备 Token 即可。

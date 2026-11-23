# FreeClipMonitor（iPhone 原生华为 FreeClip 2 真实电量监测 App）

一款专为 **iPhone + 华为 FreeClip 2** 开发的原生 SwiftUI + CoreBluetooth 工具：直接解析硬件蓝牙真实电量，**无需手动校准、无需估算**，支持**每次蓝牙断开自动扫描并推送真实三电量**、**充满 100% 自动识别**、**桌面与锁屏小组件**。

---

## 核心协议原理（已真机抓包实测验证）

1. **主通道：`FDEE` BLE 实时广播（支持开盖、合盖、插线充电状态！）**
   - 报文头：`01 02 <lid> FF ... 00 00 01 67 01 03 ... [充电盒] [耳机1] [耳机2]`
   - `lid`：`03` = 开盖，`00` = 合盖
   - 电量解码：`byte & 0x7F` 为真实百分比（0~100），`(byte & 0x80) != 0` 为充电状态
   - **实测已确认**：即便耳机放回盒内**合盖**或**合盖插线充电**，FreeClip 2 依然持续广播 `FDEE` 真实电量，充满 100% 时可直接扫描识别。
2. **辅通道：`0xFD21` GATT 串口透传**
   - Notify 特征值：`02000200-0000-2000-8000-009E78563412`
   - Write 特征值：`03000300-0000-3000-8000-009E78563412`
   - 查电量指令帧：`5A0003000108DF73`（`01 08` + CRC16-XMODEM）

---

## Windows 电脑免 Mac 编译 & 安装到 iPhone（约 5 分钟）

### 第 1 步：用 GitHub Actions 免费云端编译 `.ipa`
1. 在 GitHub 上新建一个仓库（公开或私有均可，例如 `FreeClipMonitor`）。
2. 把本目录（`C:\Users\Administrator\.gemini\antigravity\scratch\FreeClipMonitor`）的所有文件推送到该仓库的 `main` 分支：
   ```powershell
   cd C:\Users\Administrator\.gemini\antigravity\scratch\FreeClipMonitor
   git init -b main
   git add .
   git commit -m "Initial FreeClipMonitor iOS app"
   git remote add origin https://github.com/<你的用户名>/FreeClipMonitor.git
   git push -u origin main
   ```
3. 打开 GitHub 仓库页面 → 点击顶部 **Actions** → 等待 `Build FreeClipMonitor IPA` 运行变绿（约 2～3 分钟）→ 在页面底部的 **Artifacts** 中下载 **`FreeClipMonitor-IPA`**，解压得到 **`FreeClipMonitor.ipa`**。

### 第 2 步：在 Windows 上将 `.ipa` 安装到 iPhone
任选以下两种免费自签工具之一（使用自己的普通 Apple ID 即可，无需 \$99 开发者账号）：
* **推荐：SideStore**（[sidestore.io](https://sidestore.io)）  
  首次通过 Windows 电脑装一次 SideStore 到 iPhone 后，以后直接在 iPhone 上导入 `FreeClipMonitor.ipa`，并在手机上本地自动续签，**再也不用连电脑**。
* **备选：Sideloadly**（[sideloadly.io](https://sideloadly.io)）  
  Windows 打开 Sideloadly，插上 iPhone，把 `FreeClipMonitor.ipa` 拖进去输入 Apple ID 即可安装（免费 Apple ID 每 7 天需连一次电脑或同 Wi-Fi 自动续签）。

> 安装后如提示“未受信任的开发者”，在 iPhone `设置 → 通用 → VPN与设备管理` 中点击信任即可打开 App。

---

### 第 3 步：配置“每次蓝牙断开自动扫描并推送真实电量”

打开 App 授予 **蓝牙权限** 与 **通知权限** 后，在 iPhone 的 **「快捷指令」** App 里配 1 条自动化：

1. 打开「快捷指令」→ 底部 **「自动化」** → 右上角 **`+`** → 选择 **「蓝牙」**。
2. 设备选择 **HUAWEI FreeClip 2** → 勾选 **「已断开连接」** → 选择 **「立即运行」**。
3. 新建空白自动化 → 搜索并选择本 App 提供的动作：
   * **`扫描 FreeClip 2 真实电量并推送`**（推荐，100% 稳定捕获合盖后的 `FDEE` 真实广播，扫描 1~2 秒后立刻推送三项真实电量通知并刷新桌面小组件）。
   * *（也可尝试同 App 提供的 **`后台静默扫描 FreeClip 2 电量`**，不弹界面在后台通过 `FD21` / `FDEE` 尝试读取）*。
4. 桌面或锁屏长按空白处 → **`+`** → 搜索 **FreeClip 2**，即可添加桌面小组件（小号 / 中号）和锁屏小组件。

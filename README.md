# FreeClip 2 Monitor

在 iPhone 上用华为 FreeClip 2 时，系统自带的电池组件看不到充电盒电量，官方 App 又需要每次手动打开。这个项目是写给自己的小工具，用来直接通过蓝牙读取充电盒和双耳电量，并同步到桌面小组件和系统通知里。

目前处于 `v0.9.0` 公开测试阶段，仍在持续维护，遇到问题欢迎提 Issue。

## 功能

- 读取充电盒与左右耳电量，开盖、合盖、插线充电状态均可获取
- 桌面小组件（小号 / 中号）与锁屏小组件
- 蓝牙断开推送电量、充电盒低电量提醒、充满 100% 提醒
- 提供快捷指令动作，可搭配 iOS 自动化使用

## 前置条件

- **系统版本**：iOS 17.0 及以上。
- **签名工具**：因为未上架 App Store，需要通过侧载工具签名安装：
  - **已有个人 UDID 证书**（如 Feather / 轻松签）或 **TrollStore** 用户：无需电脑，直接跳到「安装 FreeClip 2」。
  - **使用免费 Apple ID**（推荐 **SideStore**）：首次安装需要一台 Windows / Mac 电脑和数据线完成初始化，之后日常更新和续签都在手机上完成。
- **VPN 与网络**：
  - SideStore 运行需要本地回环 VPN，请先在 App Store 安装 **`LocalDevVPN`**（或 StosVPN）。
  - SideStore 安装与续签时必须连接 **Wi-Fi**，且只能开启 `LocalDevVPN`（iOS 同一时间仅允许一个 VPN，操作前需先关闭其他代理工具）。
  - 访问 GitHub 软件源及下载 `.ipa` 时，如遇国内网络超时，请提前准备好网络环境或手动下载 `.ipa` 离线导入。

## 首次安装 SideStore（免费 Apple ID 方案）

如果手机上已经装好 SideStore，可跳过这一节。详细图文也可参考官方指南：[docs.sidestore.io](https://docs.sidestore.io)。

1. **在电脑上安装 SideStore 到 iPhone**
   - 推荐使用 SideStore 配套工具 **iloader**（支持 Windows / macOS，可在 [sidestore.io](https://sidestore.io) 获取）：连接数据线、在手机上点「信任此电脑」，用工具一键将 SideStore 安装到 iPhone 并自动写入配对文件。
   - 若使用传统 AltServer 方式，Windows 需安装官网版（非微软商店版）iTunes 与 iCloud，安装完 SideStore 后还需用 `JitterbugPair` 生成并导入配对文件。
2. **手机端开启信任与开发者模式**
   - 打开 `设置 → 通用 → VPN 与设备管理`，信任你的 Apple ID 证书。
   - 打开 `设置 → 隐私与安全性 → 开发者模式`，开启后按提示重启一次手机。
3. **初始化 SideStore**
   - 先打开 **`LocalDevVPN`** 并开启连接，确认手机连接着 **Wi-Fi**。
   - 打开 SideStore，进入 Settings 登录 Apple ID，并按提示刷新一次 SideStore 自身确认通道正常。

### Apple ID 登录注意事项

- **建议使用备用 Apple ID**：免费个人账号即可，不需要付费开发者账号；建议注册一个专门用于侧载的小号，避免主账号频繁触发安全验证。
- **双重认证与地区**：开启了双重认证的账号需要输入 6 位验证码；如果一直提示登录失败或账号异常，先登录 [appleid.apple.com](https://appleid.apple.com) 检查账号是否被临时锁定，或确认已同意最新的 Apple 服务条款。
- **免费账号配额限制**：同一台设备最多同时激活 **3 个**自签 App（含 SideStore 本身），每 7 天最多注册 **10 个 App ID**。本应用包含主程序和小组件，共占用 **2 个 App ID**。
- **7 天有效期**：免费签名 7 天过期，在到期前连上 Wi-Fi 和 `LocalDevVPN` 刷新一次即可重置为 7 天（下方提供一键自动续签快捷指令）。

## 安装 FreeClip 2

### 方式一：通过软件源安装（推荐，后续可一键更新）

适用于 **SideStore**、**AltStore**、**Feather** 等支持 AltStore 源格式的签名工具：

1. 连接 **Wi-Fi**，并开启 **`LocalDevVPN`**（使用 SideStore 时）。
2. 打开 SideStore → 底部 **Sources（源）** → 右上角 `+`，粘贴下面的软件源地址：
   ```
   https://raw.githubusercontent.com/miaomiaoIc3/Freeclip2-Monitor/main/source.json
   ```
3. 找到 **FreeClip 2** 点击安装。

> 安装过程中如果弹出是否保留 **App Extensions**，请务必选择**保留**，否则桌面和锁屏小组件无法显示数据。

### 方式二：直接下载 `.ipa` 安装

在 [Releases 页面](https://github.com/miaomiaoIc3/Freeclip2-Monitor/releases/latest) 下载 `FreeClipMonitor-v0.9.0.ipa`，导入 SideStore / Feather / 轻松签 / TrollStore / Sideloadly 安装即可。

> 若覆盖更新后桌面或通知横幅仍显示空白网格图标，重启一次 iPhone 清理系统图标缓存即可。

## 快捷指令配置

安装完成后，先打开一次 App 并授予**蓝牙**和**通知**权限。

### 1. 耳机断开时自动推送电量

打开 iPhone「快捷指令」→ 底部「自动化」→ 右上角 `+`：

1. 触发条件选 **蓝牙** → 设备选 **HUAWEI FreeClip 2** → 勾选 **已断开连接** → 选 **立即运行**。
2. 动作搜索本 App 提供的 **获取 FreeClip 2 电量**（如需不弹界面静默尝试，可选 **后台获取 FreeClip 2 电量**）。

### 2. SideStore 定时自动续签（免去每 7 天手动点刷新）

- 直接导入现成的快捷指令：[SideStore 自动续签（iCloud 链接）](https://www.icloud.com/shortcuts/96aa821eefc2459cbd1d342eb616cf29)
- 导入后点开编辑，确认其中的 VPN 动作已正确选中你手机上的 **`LocalDevVPN`**（如果平时常挂其他代理，可在最后一步按需加上切回动作）。
- 打开「快捷指令」→ 底部「自动化」→ `+` → 选择 **特定时间**（建议设在每天晚上连着 Wi-Fi 的时间，例如 `22:00`）→ 选 **立即运行** → 选择运行上面导入的自动续签快捷指令。

## 兼容说明与协议记录

目前仅在 **HUAWEI FreeClip 2** 上真机验证过。

App 通过两个通道读取电量：
- **BLE 广播 (`FDEE`)**：解析 `01 02 <lid> FF ... 00 00 01 67 01 03 ... [盒] [耳1] [耳2]`，低 7 位为电量百分比，最高位为充电状态。
- **GATT 服务 (`FD21`)**：向特征值发送查电量帧 `5A0003000108DF73`，解析返回报文中的三路电量。

如果你用的是 FreeClip 一代或其他华为耳机，可以用 LightBlue 抓一下广播里的 `FDEE` 数据并提交到 Issue，后续可以一起适配。

## 自行构建

仓库配置了 GitHub Actions（`.github/workflows/build-ipa.yml`），Fork 后无需 Mac，推送代码即可在云端自动编译并打包 `.ipa`。

## 说明

- 纯本地蓝牙通信，不联网，不收集任何个人数据。
- 本项目为个人开源工具（by Happenstance），与华为无任何官方关联。

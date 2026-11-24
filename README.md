# FreeClip 2 Monitor

在 iPhone 上用华为 FreeClip 2 时，系统自带的电池组件看不到充电盒电量，官方 App 又需要每次手动打开。这个项目是写给自己的小工具，用来直接通过蓝牙读取充电盒和双耳电量，并同步到桌面小组件和系统通知里。

目前处于 `v0.9.0` 公开测试阶段，仍在持续维护，遇到问题欢迎提 Issue。

## 功能

- 读取充电盒与左右耳电量，开盖、合盖、插线充电状态均可获取
- 桌面小组件（小号 / 中号）与锁屏小组件
- 蓝牙断开推送电量、充电盒低电量提醒、充满 100% 提醒
- 提供快捷指令动作，可搭配 iOS 自动化使用

## 安装方式

需要 **iOS 17.0 及以上**。App 未上架 App Store，目前提供以下两种安装途径：

### 方式一：通过软件源安装（推荐，支持后续一键更新）

适用于 **SideStore**、**AltStore**、**Feather** 等支持 AltStore 源格式的签名工具。

- **软件源地址**（在 SideStore / AltStore 的「源 / Sources」页点右上角 `+` 粘贴即可）：
  ```
  https://raw.githubusercontent.com/miaomiaoIc3/Freeclip2-Monitor/main/source.json
  ```

> 安装提示：
> 1. 弹出是否保留 **App Extensions** 时务必选择**保留**，否则桌面小组件无法正常显示。
> 2. 如果之前没装过 SideStore，首次配置 SideStore 需要连一次电脑；装好后日常更新和续签都可以在手机上完成。

### 方式二：直接下载 `.ipa` 安装

如果你已经有个人开发者 UDID 证书（轻松签 / Feather），或者使用 TrollStore、Sideloadly，可以直接在 [Releases 页面](https://github.com/miaomiaoIc3/Freeclip2-Monitor/releases/latest) 下载 `FreeClipMonitor-v0.9.0.ipa` 进行安装。

## 快捷指令配置

安装完成后，先打开一次 App 并授予**蓝牙**和**通知**权限。

### 1. 耳机断开时自动推送电量

打开 iPhone「快捷指令」→ 底部「自动化」→ 右上角 `+`：

1. 触发条件选 **蓝牙** → 设备选 **HUAWEI FreeClip 2** → 勾选 **已断开连接** → 选 **立即运行**。
2. 动作搜索本 App 提供的 **获取 FreeClip 2 电量**（如需不弹界面静默尝试，可选 **后台获取 FreeClip 2 电量**）。

### 2. SideStore 定时自动续签（可选）

使用免费 Apple ID 签名每 7 天需要续签一次，可以用快捷指令自动化省去手动操作：

1. 新建一条每天固定时间（建议在晚上连着 Wi-Fi 时）的自动化，选 **立即运行**。
2. 按顺序添加动作：
   - 设置 VPN → 连接 `LocalDevVPN`
   - 等待 `3` 秒
   - SideStore → `Refresh All Apps`（关闭「运行时显示」）
   - 设置 VPN → 断开 `LocalDevVPN`（如果平时常挂其他代理，可在最后一步切回）

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

# Fan Control

Fan Control 是使用 SwiftUI 构建的原生 macOS 风扇控制工具，功能参考 Macs Fan Control。它提供实时温度与转速监控、风扇调速、本机预设和菜单栏快捷操作。

## 功能

- 实时显示风扇最低、当前、最高转速，以及温度传感器读数。
- 支持系统自动、固定转速和温度双阈值调速，可分别配置每只风扇。
- 提供系统自动、全速散热快捷预设，以及自定义预设的保存、重命名、删除和应用。
- 菜单栏可独立配置图标、温度、转速和数据来源；同时显示温度与转速时采用上下两行。
- CPU、GPU、内存和电池平均温度置顶，具体测点按上游库提供的名称显示；缺少有效测点时不生成对应平均值。
- 支持温度排序、名称或原始键搜索，以及未识别测点筛选。
- 支持摄氏／华氏温标、显示精度、简体中文／英文界面和登录启动。
- 通过 Sparkle 自动检查 GitHub Releases 更新，提供更新说明、下载、签名验证与安装入口。
- 使用原生 macOS 材质；macOS 26 及更新系统提供 Liquid Glass 效果。
- 独立控制服务通过 XPC 通信，具备签名校验、控制权隔离、心跳超时恢复、写入前恢复日志和读回确认。

## 系统与机型支持

| 项目 | 支持范围 |
| --- | --- |
| 运行系统 | macOS 14 或更新版本 |
| 应用架构 | 仅支持 Apple Silicon（arm64） |
| 温度与转速监控 | 取决于机型公开的 SMC／HID 传感器 |
| 风扇调速 | 不限制 Apple Silicon 机型；识别到兼容控制接口和有效转速范围的风扇即可调速 |
| 无风扇或接口不兼容的设备 | 提供可用的监控功能，并显示不能调速的原因 |

应用按风扇实际提供的 SMC 接口判断能力，支持 `F?md`／`F?Md` 直接模式，按 `flt `／`fpe2` 格式写入目标转速。每次写入都进行读回确认，失败时尝试恢复系统自动。部分机型的接口可能被系统限制，读取成功不保证可以写入；不通过修改测试键或绕过热管理强制开放。全速预设作用于所有检测到的可调速风扇。

设备名称由 DeviceHardware 提供，真实温度测点名称和分类由 SiliconScopeCore 提供。

## 安装与使用

打开 DMG，将 `Fan Control.app` 拖到其中的 `Applications` 快捷入口，再从“应用程序”打开。替换已有应用前先退出正在运行的版本。

目前发布包使用 ad hoc 签名，没有 Apple Developer ID 或 Apple 公证。首次打开时，如果 macOS 阻止运行，请在“系统设置 → 隐私与安全性”中确认来源后选择“仍要打开”。应用应安装到可写的位置；不要直接从只读 DMG 中执行更新。

打开应用即可监控。首次调速时，点击“启用风扇控制…”→“安装并启用…”，由 macOS 请求管理员授权。随后选择策略并应用。关闭主窗口（红色关闭按钮或 `⌘W`）后，应用继续在菜单栏运行；关闭全部普通窗口后隐藏 Dock 图标，可从菜单栏重新打开。`⌘Q` 和“退出”会结束整个应用，包括菜单栏。

更新或重新构建后，若首次连接旧控制服务失败，应用会对当前构建自动尝试更新一次，并请求管理员授权。取消授权后，可在设置或主页弹窗中点击“更新并重新连接…”手动重试。安装器先检查旧安装签名和风扇恢复日志，再迁移服务；失败时尝试回滚。恢复尚未确认时，需先使用原版本应用恢复系统自动。

应用会记住最后一次成功应用的策略，更新、重新启动应用或睡眠唤醒后，在服务连接且最新硬件数据通过校验时自动恢复，并同步预设名称。睡眠期间风扇交由系统控制，唤醒后等待睡眠前的恢复请求完成，再重新采样和应用策略；唤醒后的恢复只对新的采样结果校验，服务在写入前明确拒绝暂时无效温度时，最多等待三个新样本后尝试恢复；已写入后的故障不重试。持续失败时保留系统控制并显示原因，不循环重新应用。主动选择“系统自动”后，下一次启动或唤醒也保持自动。旧版本未保存上次策略的记录，需要先应用一次。设置中的“恢复自动并停用服务”会移除服务并清除自动恢复记录。使用其他风扇工具时，请先在原工具中恢复系统自动并退出，避免同时控制同一风扇。

心跳独立于界面温度采样发送，执行自定义策略时避免 App Nap 延后控制通信，仍允许熄屏与正常睡眠。心跳超时或连接中断后，先确认风扇已恢复系统控制，再校验最新读数并尝试恢复原策略；恢复失败不重复写入。服务检查短暂延迟时，读取当前硬件状态并验证控制权和所需温度新鲜度，不仅凭两次检查的间隔撤销策略。过热、无效读数、写入故障或其他工具接管导致的退出不会自动重新接管。控制服务会记录具体中断原因及间隔，目标转速未变化时仍核对所有权和读数，但不重复写入 SMC。

主监控窗口可见时，监控每两秒更新；复用库返回的传感器目录及 SMC 类型信息，不重复枚举。异常读数仍走库的 HID/SMC fallback。设置页使用稳定目录，不单独触发完整温度采样。主窗口关闭、被完全遮挡、位于其他桌面或最小化时，只采样菜单栏需要的温度与转速；仅显示图标且未展开菜单时停止监控采样。后台系统自动状态不定时轮询服务，打开窗口/菜单或切换策略时再检查。用户在菜单栏切换策略时，按需补读该策略需要的最新数据。

控制服务不执行完整温度监控：固定转速和全速仅检查风扇，温度调速只独立读取所选源，平均温度使用库已识别的该组测点，并对同一测点去重读取。所选温度源首次无效时，仅重开一次 SMC 连接、清除不可用键缓存，再复核风扇状态并补读完整来源，避免深睡或重新上电后的暂时故障被永久缓存；仍缺失或无效的平均值成员会停止调速，不使用旧温度或不完整平均值。写入及恢复只访问对应风扇，不等待温度采样。控制心跳独立运行；设备信息、传感器及风扇目录和应用菜单与实时读数分开观察，设置页选择列表不会随采样重建；macOS 26 及更新系统中，风扇表头、名称和策略文字使用独立绘制，绕过已知的 SwiftUI 局部文字倒置问题；唤醒时只重建风扇区域的绘制缓存，不增加后台轮询；风扇和温度数值独立刷新，默认温度列表不随采样重新排序。菜单弹窗关闭后停止观察其数值。服务安装状态在启动、硬件能力变化、打开窗口或菜单、安装操作及连接中断时检查，不随心跳反复访问文件系统。故障恢复时临时获取必要的新读数，恢复后停止额外采样。正常控制不会重复应用策略。菜单栏内容变化时用独立 Core Graphics／Core Text 上下文一次性预绘为 Retina 位图，不切换 AppKit 当前绘图上下文；重绘时复用，仅缓存最近一张图像及固定风扇图标。界面使用的服务签名检查结果也会缓存，连接和安装仍验证当前代码身份。

## 从源码构建

工程使用 Swift 6，建议安装 Xcode 26 或更新版本。在项目根目录执行：

```sh
bash scripts/build-app.sh
open "build/Build/Products/Release/Fan Control.app"
```

脚本生成仅包含 arm64 的完整 Release 应用与控制服务，并执行签名校验。构建过程只生成产物。

生成带有 `Applications` 快捷入口的 DMG：

```sh
bash scripts/build-dmg.sh
```

产物为 `build/FanControl.dmg`。

默认使用 `/Applications/Xcode.app`，支持该路径为软连接；可通过 `DEVELOPER_DIR` 指定其他 Xcode。默认签名为 ad hoc，也可通过 `FANCONTROL_SIGN_IDENTITY` 指定自己的签名身份：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-app.sh
FANCONTROL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-dmg.sh
```

Xcode 工程为 `macs-fan-control.xcodeproj`，共享 scheme 为 `macs-fan-control`。Swift Package 管理控制服务、硬件层和核心测试的依赖。

## 自动更新与发布

无需购买 Apple 开发者账号。应用使用本地 ad hoc 代码签名；Sparkle 使用独立的 Ed25519 密钥验证更新包和更新清单，公钥嵌入应用，私钥不随源码或安装包分发。这种签名不能代替 Apple 公证。通过菜单或设置中的“检查更新…”手动检查，也可在设置中启用或关闭定期检查。安装更新需要重启应用；控制服务的信任升级仍可能请求管理员授权，完成后按最后保存的策略恢复控制。

更新源为本仓库 GitHub Releases 的 `appcast.xml`，安装包和清单同时发布到相应版本。`.github/workflows/ci.yml` 在 main 分支和 Pull Request 上运行测试并构建 arm64 DMG；`.github/workflows/release.yml` 在推送 `vmajor.minor.patch` 标签时运行测试、构建签名更新并创建 Release。工作流使用 GitHub 托管的 `macos-26`，不会访问真实风扇。

维护者在仓库的 **Settings → Secrets and variables → Actions** 中添加 `SPARKLE_PRIVATE_KEY`，内容为本机 `.secrets/sparkle.key` 的 Base64 文本。可使用 GitHub CLI 直接读取文件配置，避免将密钥打印到终端：

```sh
gh secret set SPARKLE_PRIVATE_KEY --repo itswenb/fan-control < .secrets/sparkle.key
```

私钥应单独安全备份；`.secrets/` 已被 Git 忽略。每次发布必须使用与 `Configuration/Updates.xcconfig` 公钥匹配的同一私钥。没有 Developer ID 时，不应随意更换公钥，否则已安装版本将无法验证新更新。Fork 项目应使用自己的密钥和更新源，并同步修改发布脚本中的仓库地址；新项目可运行 `swift scripts/update-key.swift generate` 生成自己的密钥，工具拒绝覆盖现有私钥。

本地生成已签名的发布产物：

```sh
FANCONTROL_VERSION=0.3.10 bash scripts/build-release.sh
```

产物位于 `build/releases/`，包含 `FanControl-0.3.10.dmg` 和带签名的 `appcast.xml`。脚本检查版本、公私钥匹配、签名、篡改拒绝和下载地址。准备好 Actions Secret 后，推送对应版本标签即可触发发布：

```sh
git tag v0.3.10
git push origin main v0.3.10
```

首次发布更新功能后，使用旧版且尚未包含 Sparkle 的用户需要手动安装一次，之后可在应用内更新。

## 测试与贡献

使用与应用构建相同的 Xcode 工具链运行核心测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build
```

核心测试覆盖控制接口识别、转速编码、调速策略、转速范围、温度读数有效性、预设持久化、会话隔离、失联恢复、恢复日志异常，以及传感器名称和平均值。控制采样测试使用 SMC 替身验证固定策略不采集温度、仅采集选中测点、平均值完整性、目标不变时不重复写入，以及监控失效时仍可恢复；应用生命周期测试覆盖健康会话不重复应用策略。模拟硬件仅用于测试。

欢迎提交问题和 Pull Request。报告机型兼容性问题时，请附上机型标识、macOS 版本、应用版本和错误信息；不要上传管理员密码、签名私钥或个人数据。新增控制接口的支持应提供硬件读回及恢复验证结果。

## 本机数据

温度、风扇读数和调速策略在本机处理。用户设置和预设保存在本机，控制服务的信任记录与恢复日志由 root 管理。源码中没有集成分析上报。

检查更新时会通过 HTTPS 访问 GitHub 获取更新清单和安装包，不上传温度、风扇策略或本机诊断报告；Sparkle 的可选系统配置上报已关闭。

## 许可证与第三方声明

本项目采用 [MIT License](LICENSE)。第三方依赖及协议参考的版权声明如下；分发应用或修改源码时，请一并保留相应声明。

| 项目 | 用途 | 许可证 |
| --- | --- | --- |
| [DeviceHardware](https://github.com/Shakshi3104/DeviceHardware) | 设备型号与人类可读名称 | MIT |
| [SiliconScopeCore 4.4.0](https://github.com/kennss/SiliconScope) | 温度采样、分类与传感器名称 | MIT |
| [Stats](https://github.com/exelban/stats) | SiliconScope 上游传感器映射资料 | MIT |
| [beltex/SMCKit](https://github.com/beltex/SMCKit) | SMC 消息布局与键枚举协议参考 | MIT |
| [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle) | 应用内自动更新与发布签名工具 | MIT 及附带第三方许可 |

Sparkle 的完整版权和附带许可保存在 [LICENSES/Sparkle.txt](LICENSES/Sparkle.txt)，并随应用分发。说明文档仅保留本 README；LICENSE 与第三方许可属于法律文件。

Stats © Serhiy Mytrovtsiy。本项目通过 SiliconScopeCore 使用上游温度映射；SMC 消息编码、数值解码和风扇控制服务由本项目实现。

<details>
<summary>DeviceHardware 版权与许可证</summary>

```text
MIT License

Copyright (c) 2020 Shakshi3104

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

</details>

<details>
<summary>SiliconScope 版权与许可证</summary>

```text
MIT License

Copyright (c) 2026 Kennt Kim (Calida Lab)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

</details>

<details>
<summary>SMCKit 参考实现版权与许可证</summary>

```text
The MIT License

Copyright (C) 2014-2017 beltex <https://beltex.github.io>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

</details>

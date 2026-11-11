# Notchfax

把 MacBook 的刘海当成出纸口的一台小机器。它常驻菜单栏，纸从屏幕顶部正中吐出来，可以抓着晃、横着撕、拖出去存成图片。

它会三件事：

| 功能 | 纸 | 说明 |
|---|---|---|
| 那年今日 | 光面相纸 | 从本机照片图库里找出往年今天拍的照片印出来，右下角是橙色点阵日期，白边上写着「N 年前的今天」 |
| 大头贴 | 四连拍竖条 | 出纸口下方降下取景框，倒计时连拍四张，印成一条。快捷键 ⌃⌥⌘B |
| 传真 | 热敏纸 | 匿名写给一位随机的陌生人。第一封只能是文字；对方回复后线路接通，才能互发图片 |

没有刘海的屏幕会在顶部正中画一个出纸口。系统开了「减少动态效果」时，走纸改为淡入淡出。

## 构建与运行

需要 macOS 14 以上、Xcode（Swift 6）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。没有第三方依赖。

```sh
xcodegen generate
xcodebuild -scheme Notchfax -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Notchfax.app
```

第一次启动会自己印一张说明小票，之后不再出现。所有功能都在菜单栏的小纸条图标里；「调试」子菜单里有各种样张和模拟手势。

测试：

```sh
cd Packages/NotchfaxKit && swift test
```

应用图标是用代码画的。改了画法以后重新生成各个尺寸：

```sh
swift scripts/make-icon.swift App/Assets.xcassets
```

## 目录

```
project.yml               XcodeGen 工程描述（生成的 .xcodeproj 不入库）
App/                      应用外壳：菜单栏、首次启动小票、调试样张、Info.plist、图标
Packages/NotchfaxKit/
  Sources/PrintKit/       出纸口、纸张渲染与物理、声音、打印队列（接口见其中的 README.md）
  Sources/Memories/       那年今日
  Sources/PhotoBooth/     大头贴
  Sources/FaxKit/         传真客户端
server/                   传真中继服务器（Cloudflare Workers，见 server/README.md）
docs/protocol.md          传真协议
scripts/make-icon.swift   生成应用图标
```

## 启动参数

都直接传给可执行文件，例如
`build/DerivedData/Build/Products/Debug/Notchfax.app/Contents/MacOS/Notchfax --demo fax,wait:3,gesture:rip`。

| 参数 | 作用 |
|---|---|
| `--render-gallery <目录>` | 把每种纸和一组动作分镜离屏渲染成 PNG，然后退出 |
| `--demo <步骤,…>` | 启动后依次执行：样张名（`fax` `photo` `strip` `all` `viewfinder` `compose` `compose-send`）、`wait:<秒>`、`gesture:<名字>`（`hover` `swing` `carry` `carry-out` `rip` `half-tear` `fling`，不发送系统事件）、`pointer-report` |
| `--simulate-notch` | 在没有刘海的屏幕上画一个刘海 |
| `--reduce-motion` | 当作系统开了「减少动态效果」 |
| `--welcome` | 再印一次首次启动的小票 |
| `--quit-after <秒>` | 到时间自动退出 |
| `--memories-sample` / `--memories-demo` | 那年今日改用程序生成的样张图库；`-demo` 还会在启动时打印 |
| `--photobooth-simulated` / `--photobooth-demo` / `--photobooth-look color\|mono\|warm` | 大头贴用模拟画面；启动即开拍；指定滤镜 |
| `--fax-server <网址>` | 这次运行使用的传真服务器 |
| `--fax-profile <名字>` | 独立的传真身份和本地数据，用来在一台 Mac 上开两个实例互发 |
| `--fax-debug-…` | 无人值守的端到端脚本，见 `Sources/FaxKit/Debug/FaxDebugRunner.swift` |
| `--fax-render-samples <目录>` | 离屏渲染传真样张后退出 |

## 传真服务器

传真要经过一台中继服务器。正式使用时把它部署到自己的 Cloudflare 账号（免费套餐够用，步骤见 [`server/README.md`](server/README.md)），然后在菜单 **传真服务器…** 里贴上地址，点「检查连接」，保存后立即生效。也可以用 `defaults write com.kadaliao.notchfax fax.serverURL <网址>`。

没有设置地址时，Debug 构建默认连接本机的 `http://127.0.0.1:8787`，Release 构建则不启用传真。

### 本地跑服务器，两个实例互发

```sh
# 终端 1：本地服务器（需要 Node 20+ 和 pnpm，全程离线）
cd server && pnpm install && pnpm dev          # http://127.0.0.1:8787

# 终端 2、3：两个身份
APP=build/DerivedData/Build/Products/Debug/Notchfax.app/Contents/MacOS/Notchfax
$APP --fax-profile alice
$APP --fax-profile bob
```

在其中一个的菜单里选「写传真…」，另一个就会收到；回复以后线路接通，可以互发图片。两个实例的纸会从同一个出纸口出来、叠在一起，这只是同机调试的现象。

传真身份是一把本机生成的密钥。Release 构建存在登录钥匙串里；Debug 构建和带 `--fax-profile` 的实例存成仅本人可读的文件，从不访问钥匙串（Debug 每次构建签名都会变，用钥匙串会反复弹出密码框）。

## 还没有在真机上验证的部分

这套代码是在一台没有刘海、没有摄像头的 Mac mini（外接 1920×1080 @2x）上开发的。下面这些只有代码路径和离屏/脚本验证，没有真实使用过：

- **真刘海**：位置和宽度取自 `NSScreen` 的安全区与辅助区域，只用「模拟刘海」检查过画面。
- **真摄像头**：大头贴在这台机器上只跑过模拟画面；真实摄像头、连续互通相机、权限弹窗没有实测。
- **真照片图库的自动打印**：手动打印跑过，每天定时那一路依赖时间和在场检测，没有等过真实的一天。
- **多显示器、全屏空间、合盖再开**：有处理代码，没有实测。
- **声音和触感**：声音全部程序合成，波形有单元测试，但没有人坐在这台机器前认真听过；触感需要带力度触控板的机器。
- **线上服务器**：只连过本地 `wrangler dev`，没有部署过。
- **签名与公证**：本地构建是 ad-hoc 签名，没有做过分发。

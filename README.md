# Notchfax

把 MacBook 的刘海当成出纸口的一台小机器。它常驻菜单栏，纸从屏幕顶部正中吐出来，可以抓着晃、横着撕、拖出去存成图片。

它会三件事：

| 功能 | 纸 | 说明 |
|---|---|---|
| 那年今日 | 光面相纸 | 从本机照片图库里找出往年今天拍的照片印出来，右下角是橙色点阵日期，白边上写着「N 年前的今天」 |
| 大头贴 | 四连拍竖条 | 出纸口下方降下取景框，倒计时连拍四张，印成一条。快捷键 ⌃⌥⌘B |
| 传真 | 热敏纸 | 匿名写给一位随机的陌生人。第一封只能是文字；对方回复后线路接通，才能互发图片 |

没有刘海的屏幕会在顶部正中画一个出纸口。系统开了「减少动态效果」时，走纸改为淡入淡出。

## 安装

```sh
brew install --cask kadaliao/tap/notchfax
```

或者到 [Releases](https://github.com/kadaliao/notchfax/releases/latest) 下载 dmg，把 Notchfax 拖进「应用程序」。需要 macOS 14 以上，Apple Silicon 和 Intel 通用。

第一次启动会请求照片图库和摄像头权限，分别用于那年今日和大头贴。传真默认连公共中继 `notchfax.liaoxingyi.com`，也可以在菜单的「传真服务器…」里换成自己部署的地址。

## 命令行

用 Homebrew 装的已经带了 `notchfax` 命令。下载 dmg 装的，在菜单里点「安装命令行工具…」，会在 `/usr/local/bin` 放一个 `notchfax`（要输一次管理员密码）。它就是 App 自己的可执行文件，所以也可以自己建链接：

```sh
ln -s /Applications/Notchfax.app/Contents/MacOS/Notchfax ~/.local/bin/notchfax
```

```sh
notchfax print 你好                         # 一张热敏小票
echo 你好 | notchfax print                  # 从管道读
notchfax print -i 截图.png "## 今天的截图"  # 图在上、字在下，图会抖成黑白点
notchfax print --photo -i 照片.jpg          # 印在光面相纸上
notchfax help                               # 全部选项
```

Notchfax 没在运行时会在后台把它打开再打印（`--no-launch` 则直接失败）。命令在打印请求排进队列时就返回，不等纸出来。退出码：0 成功，1 被 App 拒绝（比如内容太长），2 用法或输入有误，3 连不上 App。

文字支持几个行首标记，用来排小票：

| 写法 | 效果 |
|---|---|
| `# 标题` | 大号粗体，居中 |
| `## 文字` | 粗体 |
| `> 文字` | 小字 |
| `^ 文字` | 居中，可以叠在别的标记前面：`^ > 谢谢惠顾` |
| `---` / `===` | 虚线 / 实线 |
| `左<Tab>右` | 两栏，右栏靠右，适合写价格 |

不想解析标记就加 `--plain`，文字会原样印出来。一张纸最高约 1400 点，印不下会报错，不会截断。

### AI 会话小票

想让 Claude Code、Codex、Cursor、OpenCode 这类编程助手每干完一次活就打一张小票，点菜单里的「AI 会话小票…」：拷贝里面的提示词发给你的 AI，它会用自己的钩子或插件机制装好，再打一张样票给你看。各家的钩子和会话记录格式都不一样，也一直在变，所以 Notchfax 不替它们装，只提供 `notchfax print` 这个出口。面板里的「打一张样票」可以先看看小票长什么样。

[`integrations/`](integrations/) 里有 Claude Code、Pi、OpenCode、DeepSeek Harness 桌面版的现成实现，提示词会让 AI 先看这些：是这几家就直接装，别家照着改。那里的 README 写了几家共同的做法和统一的小票格式。

### Claude Code 会话小票

[`integrations/claude-code/notchfax-receipt.py`](integrations/claude-code/notchfax-receipt.py) 是一个 Claude Code 的 SessionEnd hook：会话结束时，按转录里的 token 用量和 API 标价算出这次花了多少钱，印成一张小票（分模型列出输入、输出、缓存读写，含子代理）。放到稳定的位置，再加进 `~/.claude/settings.json`：

```json
"hooks": {
  "SessionEnd": [
    {"hooks": [{"type": "command", "command": "/usr/bin/python3 /path/to/notchfax-receipt.py", "timeout": 5}]}
  ]
}
```

默认只给有人在场的会话出小票（终端、桌面 App、IDE），`claude -p` 和 SDK 驱动的自动任务不出。同一个会话再次结束时只结新增的部分。用环境变量调整：`NOTCHFAX_RECEIPT_ENTRYPOINTS`（哪些入口出小票，`*` 为全部）、`NOTCHFAX_RECEIPT_MIN_USD`（低于这个数不打，默认 0.01）、`NOTCHFAX_RECEIPT_CNY_RATE`（顺便折成人民币）。

会话还没结束也能随时打一张到目前为止的对账单（不算结账，结束时的小票照样按全部用量出）；加 `--dry-run` 只在终端里显示：

```sh
python3 integrations/claude-code/notchfax-receipt.py --session <会话 ID>
```

## 从源码构建

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
  Sources/RemotePrint/    命令行打印：notchfax 命令、App 里的接收端、小票排版
integrations/             AI 会话小票的现成实现（Claude Code、Pi、OpenCode、DSH）和共同做法
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
| `--photobooth-simulated` / `--photobooth-demo` / `--photobooth-look cartoon\|comic\|sketch\|pop\|dreamy\|instant\|warm\|cool\|mono\|color` | 大头贴用模拟画面；启动即开拍；指定滤镜 |
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
- **「安装命令行工具…」**：要弹管理员密码框，只验证过拼出来的命令，没有点过一次完整流程；`notchfax` 命令本身和 Claude Code 小票 hook 都实际跑过；Pi、OpenCode、DSH 的插件在作者机器上用着，仓库里整理过的版本只手动跑过出票脚本（`--dry-run`），还没在各家里重新装一遍。

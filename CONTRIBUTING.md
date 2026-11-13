# 参与 Notchfax

谢谢你愿意帮忙。这份文档写给要改代码的人：怎么构建、怎么测试、代码在哪、提交和发版的规矩。

## 提问和报错

- **报错**：用 [错误报告](https://github.com/kadaliao/notchfax/issues/new?template=bug_report.yml) 模板。写清 macOS 版本、机型（有没有刘海）、Notchfax 版本，以及怎么复现。纸的动画问题最好附一段录屏。
- **想要新功能**：先用 [功能建议](https://github.com/kadaliao/notchfax/issues/new?template=feature_request.yml) 开 issue 聊一下，避免做完了方向不合。
- **安全问题**（比如传真中继能被绕过的漏洞）：不要开公开 issue，发邮件到 kadaliao@gmail.com。

## 开发环境

| 部分 | 需要 |
|---|---|
| App 和 `NotchfaxKit` | macOS 14 以上、Xcode（Swift 6）、[XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| 传真中继 `server/` | Node 20 以上、pnpm 8 |
| 宣传片和 README 动画 `promo/` | ffmpeg、`img2webp`（`brew install ffmpeg webp`） |

App 没有第三方依赖，请保持这样：需要的东西尽量用系统框架写。

## 构建和运行

```sh
xcodegen generate     # 生成 Notchfax.xcodeproj（不入库）
xcodebuild -scheme Notchfax -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Notchfax.app
```

第一次启动会印一张说明小票。菜单里的「调试」子菜单有各种样张和模拟手势。

### 启动参数

都直接传给可执行文件，例如：

```sh
build/DerivedData/Build/Products/Debug/Notchfax.app/Contents/MacOS/Notchfax --demo fax,wait:3,gesture:rip
```

| 参数 | 作用 |
|---|---|
| `--render-gallery <目录>` | 把每种纸和一组动作分镜离屏渲染成 PNG，然后退出 |
| `--demo <步骤,…>` | 启动后依次执行：样张名（`fax` `photo` `strip` `all` `viewfinder` `compose` `compose-send`）、`wait:<秒>`、`gesture:<名字>`（`hover` `swing` `carry` `carry-out` `rip` `half-tear` `fling`，不发送系统事件）、`pointer-report` |
| `--simulate-notch` | 在没有刘海的屏幕上画一个刘海 |
| `--reduce-motion` | 当作系统开了「减少动态效果」 |
| `--welcome` | 再印一次首次启动的小票 |
| `--quit-after <秒>` | 到时间自动退出 |
| `--memories-sample` / `--memories-demo` | 那年今日改用程序生成的样张图库；`-demo` 还会在启动时打印 |
| `--photobooth-simulated` / `--photobooth-demo` / `--photobooth-look <滤镜>` | 大头贴用模拟画面；启动即开拍；指定滤镜（`cartoon` `comic` `sketch` `pop` `dreamy` `instant` `warm` `cool` `mono` `color`） |
| `--fax-server <网址>` | 这次运行使用的传真服务器 |
| `--fax-profile <名字>` | 独立的传真身份和本地数据，用来在一台 Mac 上开两个实例互发 |
| `--fax-debug-…` | 无人值守的端到端脚本，见 `Sources/FaxKit/Debug/FaxDebugRunner.swift` |
| `--fax-render-samples <目录>` | 离屏渲染传真样张后退出 |

没有摄像头、没有刘海的机器也能开发：`--simulate-notch` 加 `--photobooth-simulated` 就能看全部画面。

## 测试

提交前请确认这几项都过：

```sh
cd Packages/NotchfaxKit && swift test     # App 的全部逻辑：纸的物理、渲染、协议、命令行、小票排版
cd server && pnpm test && pnpm typecheck  # 中继服务器
```

CI 在每次推送和 PR 上跑同样的命令。改了画面的，请附改动前后的截图或录屏（`--render-gallery` 能离屏出图）。

## 传真中继

### 本地跑服务器，两个实例互发

```sh
# 终端 1：本地服务器（全程离线，不需要 Cloudflare 账号）
cd server && pnpm install && pnpm dev          # http://127.0.0.1:8787

# 终端 2、3：两个身份
APP=build/DerivedData/Build/Products/Debug/Notchfax.app/Contents/MacOS/Notchfax
$APP --fax-profile alice
$APP --fax-profile bob
```

在其中一个的菜单里选「写传真…」，另一个就会收到；回复以后线路接通，可以互发图片。两个实例的纸会从同一个出纸口出来、叠在一起，这只是同机调试的现象。

服务器地址按这个顺序取：`--fax-server` 启动参数，菜单「传真服务器…」里存的地址（也可以 `defaults write com.kadaliao.notchfax fax.serverURL <网址>`），最后是默认值：Debug 构建连 `http://127.0.0.1:8787`，Release 构建连公共中继 `https://notchfax.liaoxingyi.com`。

传真身份是一把本机生成的密钥。Release 构建存在登录钥匙串里；Debug 构建和带 `--fax-profile` 的实例存成仅本人可读的文件，从不访问钥匙串（Debug 每次构建签名都会变，用钥匙串会反复弹出密码框）。

协议在 [`docs/protocol.md`](docs/protocol.md)，服务器的部署、限额和设计取舍在 [`server/README.md`](server/README.md)。改协议要两边一起改，并更新协议文档。

## 目录

```text
project.yml               XcodeGen 工程描述（生成的 .xcodeproj 不入库）
App/                      应用外壳：菜单栏、首次启动小票、调试样张、Info.plist、图标
Packages/NotchfaxKit/
  Sources/PrintKit/       出纸口、纸张渲染与物理、声音、打印队列（接口见其中的 README.md）
  Sources/Memories/       那年今日
  Sources/PhotoBooth/     大头贴
  Sources/FaxKit/         传真客户端
  Sources/RemotePrint/    命令行打印：notchfax 命令、App 里的接收端、小票排版、AI 会话小票面板
integrations/             各家编程助手的会话小票实现和共同做法
server/                   传真中继服务器（Cloudflare Workers）
docs/protocol.md          传真协议
docs/media/               README 里的演示动画（由 promo/readme-media.sh 生成）
promo/                    宣传片渲染器：用 App 自己的走纸引擎离屏逐帧出画面
scripts/                  发版脚本、应用图标生成
```

## 加一家编程助手的会话小票

1. 在 `integrations/<助手>/` 下放实现和 README（怎么装、怎么关、怎么手动打一张）。
2. 照 [`integrations/README.md`](integrations/README.md) 的共同做法和小票格式来，并在那里的表格里加一行。
3. 只放在作者或你自己机器上真实跑过的实现，PR 里贴一张 `--dry-run` 的输出。
4. 在 `Packages/NotchfaxKit/Sources/RemotePrint/AgentReceipt.swift` 的 `readyMade` 里加上它，提示词会自动列出来；测试会检查目录在不在。

## 代码风格

- 跟着周围的代码写：Swift 6 严格并发，注释写「为什么」而不是「做了什么」。
- 界面文字、小票文字用简体中文，口语、短句，不用感叹号。
- 动画遵守「减少动态效果」：新加的动效要有对应的淡入淡出版本。

## 提交信息

用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 的格式，英文写：

```text
feat(photobooth): add drawn and film looks, default to cartoon
fix(photobooth): test grain against the look without it
docs: …
chore: release 0.2.2
```

范围（括号里的）用模块名：`printkit`、`memories`、`photobooth`、`fax`、`receipt`、`server`、`integrations`、`promo`。正文写清为什么改、怎么验证的。

## 发版

只有维护者发版。步骤：

1. 在 [CHANGELOG.md](CHANGELOG.md) 里把「未发布」改成新版本号和日期。
2. 改 `project.yml` 和 `App/Info.plist` 里的 `CFBundleShortVersionString`（版本号）和 `CFBundleVersion`（每次加一），提交 `chore: release x.y.z`，打标签 `vx.y.z`。
3. `NOTARY_PROFILE=notary scripts/release.sh`：构建、用 Developer ID 签名、公证，产出 `build/release/` 下的 dmg、zip 和 `SHA256SUMS`。
4. `gh release create vx.y.z build/release/*`，说明照 CHANGELOG 写。
5. 更新 [kadaliao/homebrew-tap](https://github.com/kadaliao/homebrew-tap) 里 `Casks/notchfax.rb` 的版本号和 dmg 的 sha256。

## README 的演示动画

`docs/media/*.webp` 是从宣传片画面截出来的循环动画：

```sh
cd promo
swift build && .build/debug/film    # 渲染宣传片画面 → out/video.mp4（较慢）
./readme-media.sh                   # 截几段压成动画 WebP → ../docs/media/
```

截取的时间点写在 `readme-media.sh` 里，对应 `promo/Sources/film/main.swift` 的镜头表；改了片子要回来对一遍。

## 许可

提交的代码按本项目的 [MIT 许可](LICENSE) 发布。

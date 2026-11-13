## 改了什么 / What

<!-- 一两句话说清楚改了什么、为什么改。关联的 issue 写 Fixes #123。 -->

## 怎么验证的 / How it was checked

<!-- 跑了哪些测试；改了画面的，附改动前后的截图或录屏。 -->

- [ ] `cd Packages/NotchfaxKit && swift test`
- [ ] `cd server && pnpm test && pnpm typecheck`（改了 server/ 才需要）
- [ ] 在真机上试过（写明机型，有没有刘海）

## 检查 / Checklist

- [ ] 提交信息用 Conventional Commits 格式（见 CONTRIBUTING.md）
- [ ] 用户能看到的改动记在 CHANGELOG.md 的「未发布」下
- [ ] 改了协议的，`docs/protocol.md` 和 `server/` 一起改了

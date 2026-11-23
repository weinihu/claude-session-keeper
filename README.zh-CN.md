<p align="center">
  <img src="docs/icon.png" width="128" alt="图标">
</p>

<h1 align="center">Claude 换号助手（Session Keeper for Claude）</h1>

<p align="center">
  <b>Claude 换号不丢对话。</b>切换账号后，Claude Code 的历史对话一键回来。<br>
  一个很小的 macOS 工具，让 Code 标签页的对话跟着你走。
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/badge/下载-macOS-orange?logo=apple" alt="下载"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <a href="README.md"><img src="https://img.shields.io/badge/docs-English-lightgrey" alt="English"></a>
</p>

<p align="center"><img src="docs/screenshot-zh.png" width="720" alt="截图"></p>

## 遇到的问题

你有好几个 Claude 账号，比如工作号和个人号、团队号和个人号。在 **Claude 桌面版**里每换一次号，**Code 标签页的侧边栏就空了**：之前的 Claude Code 对话、项目、历史记录全都"消失"，本地项目还得重新添加一遍。

其实对话并没有被删掉，聊天记录都还在电脑上。只是 Claude **给每个账号单独保存一份侧边栏列表**。

## 它能做什么

- **换号后点一下就行：** 登录新账号大约一分钟后，会弹出"检测到你换了账号，现在恢复吗？"。点「现在恢复」，之前的对话就都回到侧边栏了，点进去可以接着聊，项目也不用重新添加。
- **各账号额度一目了然：** 一个列表里列出每个账号的 **邮箱**、**5 小时额度** 和 **每周额度** 用了多少，以及大概什么时候恢复，换号时一眼就知道该切到哪个号。还可以给账号起名字，比如"工作号""个人号"。数据来自 Claude App 已经记在你电脑上的用量，不联网获取。
- **每分钟自动备份：** 就算你直接退出登录，对话列表也早就存好了。只有内容变了才会写入，只占几 MB。
- **删掉的不会再回来：** 你在 Claude 里删掉的对话，会同时从所有账号里删除，以后也不会再恢复。
- **保持整洁（可选）：** 可以设置"每个项目只保留最近 X 天内最新的 N 个对话"。恢复时只带这些过去，点「清理旧对话」时也按这个规则清理。
- **项目搬过家也没关系：** 改了项目文件夹的名字或位置，对话会自动跟到新路径。
- **安全：** 只读写本机文件，不联网，不碰登录信息、token 和账号设置。每次恢复和清理之前都会自动留一份快照，点「撤销上次操作」就能回到原样。

## 安装

1. 在 [Releases](../../releases/latest) 下载 **`SessionKeeper-macOS.zip`**，解压后把 App 拖进「应用程序」。
2. 第一次打开：因为这个 App 没有经过 Apple 公证，需要 **右键 → 打开 → 打开**。也可以去「系统设置 → 隐私与安全性 → 仍要打开」。
3. 装好了。自动备份会自己打开。

> 需要 macOS 14 或更高版本、Claude 桌面版，以及 Python 3。Python 3 随 Apple 命令行工具一起提供；如果没有，在终端运行 `xcode-select --install`。

### Windows（测试版）

1. 在 [Releases](../../releases/latest) 下载 **`SessionKeeper-Windows.zip`**，解压到任意位置，两个 `.exe` 文件要放在一起。
2. 运行 **SessionKeeper.exe**。如果 Windows 弹出 SmartScreen 提示，点「更多信息 → 仍要运行」（这个程序没有代码签名）。
3. 如果它找不到 Claude 的数据，打开「设置」，选择包含 `claude-code-sessions` 和 `config.json` 的那个文件夹。

Windows 版刚做出来，还没有在各种 Claude 桌面版安装方式上都测过；有快照和「撤销」兜底，不会丢东西。

## 怎么用

| 什么时候 | 做什么 |
|---|---|
| 平时 | 什么都不用做，后台会自动备份 |
| 换号之后 | 打开一次 **Code** 标签页，弹窗出来后点「现在恢复」，Claude 会在大约 10 秒内重启 |
| 恢复后觉得不对 | 点「撤销上次操作」 |
| 对话太多太乱 | 打开「只保留最近的对话」，再点「清理旧对话」 |

## 原理

| 内容 | 位置 | 所有账号共用吗 |
|---|---|---|
| 对话记录 | `~/.claude/projects/<项目>/<id>.jsonl` | ✅ 共用 |
| 侧边栏列表 | `~/Library/Application Support/Claude/claude-code-sessions/<账号>/<组织>/local_*.json` | ❌ 每个账号一份 |

本工具会把侧边栏列表备份到本地保险库 `~/.claude/session-vault/`。换号后，在 Claude 退出的状态下，把这些列表条目写进新账号的列表。如果某段旧对话在任何列表里都找不到，就根据对话记录重新生成一条。

命令行用法和配置项见 [English README](README.md#how-it-works)。

## 各账号额度

Claude App 会把当前登录账号的用量（5 小时额度百分比和每周额度百分比）记在 `~/Library/Application Support/Claude/plan-usage-history.json` 里。本工具读取这个文件，把更长的历史存进保险库，再把所有账号并排显示出来：

- **只有当前登录的账号会更新。** 其他账号显示的是你最后一次用它时的情况。如果离那时已经超过 5 小时，5 小时额度会显示为"应已恢复"（估计）。
- **恢复时间是估计值。** 5 小时额度按连续使用开始的时间推算；每周额度按重置后第一次使用的时间再加 7 天推算。
- **邮箱** 来自 Claude Code 在 `~/.claude.json` 里保存的账号信息（不读 token）。每个账号第一次登录时就会被记下来，只保存在你的 Mac 上。
- **「刷新」** 会重新读取本机记录。想更新别的账号的数据，登录那个账号正常使用即可。

默认情况下，本工具不访问 Anthropic 的服务器，不读取 token，只显示 Claude 自己已经记下来的数据。

**精确模式（可选）：** 在「设置」里可以打开「精确模式」。开启后，在你用过 Claude 之后（最多 10 分钟一次、每天最多 60 次），用 Claude Code 自己保存的登录凭证，向 Anthropic 查询一次当前登录账号的额度（和 Claude Code 的 `/usage` 命令是同一个接口），百分比和重置时间都是官方数字。凭证只用于这次查询，不保存、不刷新、不发往别处。开启时会锁定当前网络：断网不查询，出口 IP、网关、代理或 VPN 一变就自动关闭；连续出错也会自动关闭。它覆盖的是命令行版 Claude Code 登录的那个号。这个接口没有公开文档，以后可能会变。

## 常见问题

**会影响我的 Claude 账号吗？** 不会。它只读写你 Mac 上的本地文件，不会往外发送任何数据。

**Claude Code 命令行版也需要吗？** 不需要。命令行版本来就在所有登录之间共用 `~/.claude`。这个工具是给**桌面版的 Code 标签页**用的，它的侧边栏是每个账号一份。

**为什么某个账号显示的是旧数据？** 用量只在账号登录时才会被记录。登录那个账号、打开一次 Code 标签页，再点「刷新」就行。

**Claude 更新后还能用吗？** 侧边栏的格式没有官方说明，有可能会失效。有快照和「撤销上次操作」兜底，不会丢东西。欢迎提 Issue 或 PR。

**Windows 版能用吗？** 能，在 Releases 下载 `SessionKeeper-Windows.zip`。它由 GitHub Actions 在 Windows 上自动打包并做过界面冒烟测试，但还比较新，建议保留快照。Linux 暂不支持。

## 赞助

> **广告** — [**tutu8.shop**](https://tutu8.shop)：作者自营的 **AI 会员代充值** 网站（第三方服务，与 Anthropic 及任何 AI 厂商无关）。在这里下单，就是在支持这个项目继续更新。

## 声明

本项目与 Anthropic 无关，也未获得 Anthropic 认可。"Claude" 是 Anthropic, PBC 的商标。本工具读写的是 Claude 桌面版没有公开文档的本地文件，请自行承担使用风险。

## 开源协议

[MIT](LICENSE)

---

<sub>关键词：Claude 换号 · Claude 多账号 · 切换账号对话消失 · Claude Code 历史对话恢复 · Claude Code 对话丢失 · Claude 桌面版 Code 侧边栏空了 · Claude 账号切换 · Claude Code 会话备份</sub>

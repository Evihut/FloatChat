# FloatChat

A tiny always-on-top macOS chat window for the AI agent CLIs you already use: **Claude Code** and **OpenAI Codex**.

macOS 上的悬浮置顶小窗，背后直接调用你本机的 `claude` / `codex` 命令行。读文件、跑命令、搜索、看图这些工具调用都由 CLI 完成，用的是你现有的订阅，不需要另外的 API Key。

- **很小**：原生 Swift，约 1.8 MB（同时支持 Apple Silicon 和 Intel），不在 Dock 显示
- **随叫随到**：`⌥Space` 呼出/隐藏，所有桌面和全屏 App 上都能显示，点它不会抢走当前 App 的焦点
- **一个对话，两个后端**：对话中途在 Claude 和 Codex 之间切换，之前的聊天记录会自动带过去
- **对话历史**：自动保存，可以搜索，点开就能接着聊（CLI 的会话也会接上）
- **图片**：`⌘V` 粘贴、拖进窗口、选文件，或者一键框选截图
- **权限开关**：默认只读（只能读文件、搜索），打开"完全权限"才允许改文件、执行命令

## 安装

**下载**：从 [Releases](../../releases) 下载 `FloatChat.zip`，解压后把 `FloatChat.app` 拖进"应用程序"。这个 App 没有经过 Apple 公证，第一次打开前要在终端运行：

```bash
xattr -dr com.apple.quarantine /Applications/FloatChat.app
```

**从源码构建**（需要 Xcode 或 Command Line Tools）：

```bash
git clone https://github.com/Evihut/FloatChat.git
cd FloatChat
./build.sh
open build/FloatChat.app
```

## 前提

先确认 CLI 在终端里能正常用：

```bash
claude -p "hi"
codex exec "hi"
```

FloatChat 只负责把它们的输出流显示出来，登录、模型、MCP 等配置都沿用 CLI 自己的。

## 用法

| 操作 | 方式 |
| --- | --- |
| 呼出 / 隐藏 | `⌥Space`（被别的 App 占用时自动改用 `⌃⌥Space`，菜单栏图标里能看到） |
| 发送 / 隐藏 | `Enter` / `Esc` |
| 附图 | `⌘V`、拖入、`+` 按钮、相机按钮截图 |
| 切换后端 | 顶栏下拉菜单 |
| 历史 / 新对话 / 置顶 / 设置 | 顶栏图标 |

第一次截图时，需要在 系统设置 → 隐私与安全性 → 录屏 里允许 FloatChat。

设置里可以改工作目录（CLI 在哪个文件夹下运行），也可以为每个后端单独指定模型。

## 工作原理

每条消息启动一次 CLI 子进程，FloatChat 读取它输出的 JSON 事件流：

- Claude：`claude -p --output-format stream-json --include-partial-messages [--resume <id>]`
- Codex：`codex exec [resume <id>] --json -`

对话保存在 `~/Library/Application Support/FloatChat/conversations/`。

## 局限

- 只支持 macOS 14 及以上
- 每条消息都要重新启动一次 CLI，第一个字出来前会等几秒
- Markdown 只渲染行内格式（粗体、代码、链接），代码块按原样显示

## License

MIT

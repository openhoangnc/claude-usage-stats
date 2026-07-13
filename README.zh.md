[English](README.md) · [日本語](README.ja.md) · [Tiếng Việt](README.vi.md) · **中文**

# Claude Usage Stats

一个小巧的 macOS 菜单栏应用，让你一眼看到 Claude Code 的使用情况——与
`claude /usage` 命令相同的数字，始终可见。

- **上行** — 当前**会话（session）**使用率 %
- **下行** — 当前**本周（所有模型）**使用率 %
- **点击** — 展开详情面板，包含全部三个时间窗口（会话、本周所有模型，以及你当前
  所用模型的每周上限），每项都带有进度条和一行重置信息，显示本地时间以及距离重置
  还有多久。

![Claude Usage Stats 截图](screenshot.png)

这两个百分比会**根据使用率区间自动着色**，所用颜色经过验证，在浅色和深色菜单栏下
均满足 **WCAG AAA**（对比度 ≥ 7:1）：

| 区间 | < 50 | 50–69 | 70–84 | 85–94 | ≥ 95 |
|------|------|-------|-------|-------|------|
| 颜色 | 绿色 | 青柠色 | 金色 | 橙色 | 红色 |

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/install.sh | bash
```

下载最新的预构建版本，安装到 `/Applications` 并启动——无需 Xcode。（如果尚无可用
版本，则会回退到从源码构建，这需要 Xcode 命令行工具。）在菜单中启用**开机自启动**
（点击指示器 → Launch at Login）。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/uninstall.sh | bash
```

## 工作原理

应用从本地的 `claude` CLI 工具获取你的使用上限，优先使用开销最小的方式：

1. 在交互式登录 shell 的 `PATH`（`/bin/zsh -ilc`）中定位 `claude`（这样 nvm/fnm/volta
   和自定义前缀都能被解析到）。
2. 运行 `claude -p /usage`（无界面）。如果该输出已包含上限进度条，则解析并渲染——完成。
3. 否则（近期的 CLI 版本已从无界面输出中移除了这些进度条），改为在伪终端中驱动交互式
   `/usage` 视图，抓取渲染出的进度条，并在开始任何对话轮次之前退出——因此不会向磁盘写入
   任何内容，也不会影响你的使用统计。

获取过程为单飞（single-flight，绝不会同时运行两个 `claude` 进程）；当使用上限接口被限流时，
会作为临时退避（back-off）处理，而不是报错。

无需访问钥匙串（Keychain）。应用不会接触你的凭据。

**首次启动：** 只要机器上已安装 `claude` 且你已登录，应用即可开箱即用，无需额外权限。

**找不到命令：** 如果 `claude` 命令不可用，应用会显示一个警告面板，建议你安装它。

## 从源码构建并安装

想自己构建？克隆仓库并运行安装脚本。从本地检出运行时，`install.sh` 会把你当前的
源码编译成通用（universal）二进制，安装到 `/Applications` 并启动——不下载任何
东西，因此运行的正是你手上的代码。

```bash
git clone https://github.com/openhoangnc/claude-usage-stats.git
cd claude-usage-stats
./install.sh
```

启动后，在菜单中启用**开机自启动**（点击指示器 → Launch at Login）。

## 环境要求

- macOS 11 及以上
- 本机已安装 Claude CLI（`claude`）并已登录
- 构建需要 Xcode 命令行工具（`swiftc`）

## 调试

```bash
# 不启动 GUI，直接打印菜单栏 / 面板将显示的内容。
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --selftest

# 从真实视图重新渲染 README 截图。
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --screenshot screenshot.png
```

刷新每 5 分钟执行一次，并在你每次打开菜单时执行，连续出错时会逐步退避。面板底部会显示
数据的最后更新时间。

# 🦞 OpenClaw 全量恢复指南（含所有密钥）

> 新电脑拿到这个文档，立刻能恢复蛋蛋、桐桐、宵宵、tiny、smile 全家！  
> ⚠️ **此文件包含所有敏感信息，请妥善保管！**  
> 创建日期：2026-04-29

---

## 🔑 第一部分：所有密钥和账号

### 🚀 OpenClaw Gateway

- **Token: （自行填入）
- **端口:** 9000

---

### ☁️ 阿里云百炼（qwen）- 默认使用

| 项目 | 值 |
|------|-----|
| **Base URL** | `https://coding.dashscope.aliyuncs.com/v1` |
| **模型** | `qwen3.5-plus` |
| **API Key: （自行填入）

---

### 🌋 火山方舟（volcengine-ark）- 会死机慎用

| 项目 | 值 |
|------|-----|
| **Base URL** | `https://ark.cn-beijing.volces.com/v1` |
| **模型** | `doubao-seed-2-0-code-preview-260215` |
| **API Key: （自行填入）

---

### 🔵 MiniMax Coding Plan

| 项目 | 值 |
|------|-----|
| **Base URL** | `https://api.minimax.chat/v1` |
| **模型** | `MiniMax-M2.5` |
| **API Key: （自行填入）

---

### 🔍 Tavily 搜索

| 项目 | 值 |
|------|-----|
| **API Key: （自行填入）

---

### 📧 Gmail 邮箱

| 项目 | 值 |
|------|-----|
| **邮箱地址** | `yangyongyy624@gmail.com` |
| **API Key: （自行填入）
| **Connection ID** | `ae33b704-2019-47c4-b1d0-4c372dd14002` |

---

### 🐙 GitHub

| 项目 | 值 |
|------|-----|
| **用户名** | `yangyongyy624-cmd` |
| **Token: （自行填入）

---

### 🐦 飞书（Feishu）

| 项目 | 值 |
|------|-----|
| **App ID** | `cli_a93ad8dcc9389cd2` |
| **App Secret** | （见飞书开放平台） |
| **Webhook Path** | `/feishu/events` |

---

### 🖥️ 远程 Mac mini（wangdemacdeMac-mini.local）

| 项目 | 值 |
|------|-----|
| **IP** | `192.168.0.109` |
| **用户** | `wangdemac` |
| **火山方舟 API Key: （自行填入）
| **模型** | `qwen3.6-plus`（阿里云百炼，已改回） |

---

## 📦 第二部分：工作区路径

| Agent | 路径 |
|-------|------|
| 蛋蛋（dandan） | `~/.openclaw/workspace-dandan/` |
| 桐桐（tongtong） | `~/.openclaw/workspace-tongtong/` |
| 宵宵（xiaoxiao） | `~/.openclaw/workspace-xiaoxiao/` |
| tiny | `~/.openclaw/workspace-xiaoxiao/`（复用宵宵） |
| smile | `~/.openclaw/workspace/smile/` |
| 爱马仕（Hermes） | `~/.openclaw/agents/hermes/` |

---

## 🛠️ 第三部分：关键文件清单

### 蛋蛋工作区必须恢复的文件

```
~/.openclaw/workspace-dandan/
├── SOUL.md          # 蛋蛋的灵魂设定
├── USER.md          # 爸爸的信息
├── IDENTITY.md      # 蛋蛋的身份
├── AGENTS.md        # Agent 规则
├── MEMORY.md        # 长期记忆
├── TOOLS.md         # 所有密钥（上面都有了）
├── memory/          # 每日记忆文件夹
│   ├── 2026-04-27.md
│   ├── 2026-04-28.md
│   └── 2026-04-29-gateway-allowlist.md
└── skills/          # 80个技能（见下方列表）
```

---

## 📚 第四部分：80个技能完整列表

```
agent-browser-clawdbot
apple-reminders
audio-video-to-text
automation-workflows
baoyu-article-illustrator
baoyu-comic
baoyu-compress-image
baoyu-cover-image
baoyu-format-markdown
baoyu-image-gen
baoyu-infographic
baoyu-markdown-to-html
baoyu-post-to-wechat
baoyu-slide-deck
baoyu-translate
baoyu-url-to-markdown
baoyu-xhs-images
calendar
china-stock-analysis
code
cron-setup
csv
document-pro
document-summary
file-manager
file-organizer-zh
git-essentials
git-helper
github
gmail
local-first-llm
local-whisper
memory-enhanced
multi-search-engine
news-aggregator
notion
ocr-local
office
office-generator-py
office-to-pdf
ollama-local
openclaw-agent-browser-clawdbot
openclaw-agent-team-orchestration
openclaw-auto-updater
openclaw-backup
openclaw-multi-instance-recovery
pdf-processing
pdf-to-word
performance-tuning
powerpoint-pptx-1-0-1
pptx-generator
scale-data-entry
scrape-web
screenshot-capture
self-improving-agent
skill-finder-cn-pro
skill-vetter-v2
slack
subagent-driven-development
summarize
tavily-search
todo
weather
weekly-system-check
word
word-docx
youtube-watcher
医疗量表制作全流程
量表制作
量表制作 - 最佳实践
量表录入中速版
量表录入快速版
量表录入慢速版
```

---

## 🔄 第五部分：快速恢复命令

```bash
# 1. 安装 OpenClaw
brew install openclaw

# 2. 初始化配置文件（把上面的密钥填入）
openclaw config edit

# 3. 创建工作区目录
mkdir -p ~/.openclaw/workspace-dandan
mkdir -p ~/.openclaw/workspace-tongtong
mkdir -p ~/.openclaw/workspace-xiaoxiao
mkdir -p ~/.openclaw/workspace/smile

# 4. 启动服务
openclaw gateway start
openclaw daemon start
```

---

## 🆘 第六部分：故障排查

| 问题 | 解决方法 |
|------|----------|
| 飞书无法登录 | 检查 App ID / App Secret |
| 模型无法调用 | 检查 API Key: （自行填入）
| Gateway 无法启动 | 检查端口 9000 是否被占用 |
| Hermes 无法工作 | 检查 `~/.openclaw/agents/hermes/config.yaml` |

---

## ☁️ Cloudcold 备份

> 如果上面的都搞不定，最后的救星！

备份位置：`~/Desktop/OpenClaw_Backups/`

| 文件 | 大小 |
|------|------|
| OpenClaw_Daily_Cycle_13.tar.gz | 4.1 GB |
| OpenClaw_Daily_Cycle_10.tar.gz | 3.5 GB |
| OpenClaw_Daily_Cycle_8.tar.gz | 3.5 GB |

恢复命令：
```bash
tar -xzf OpenClaw_Daily_Cycle_13.tar.gz -C ~/
```

---

**⚠️ 警告：此文件包含所有敏感信息，请勿外传！**  
**维护者：** 蛋蛋 🥚  
**最后更新：** 2026-04-29

# a2a-dispatcher v6.4.5 更新记录

**更新日期**: 2026-08-16 22:57

---

## 修复问题

### 问题 1：OpenAlex 限额用尽时浪费 4 轮重试

**症状**：dispatcher 对 OpenAlex 做 4 轮降级重试（去关键词 → 首词 → 兜底），但限额用尽时所有重试都 429

**根因**：没检测 HTTP 429 + "Insufficient budget"，盲目重试，每次重试 25s × 4 = 100s 浪费

**修复**：
```bash
# 旧版
local raw=$(curl -s --max-time 25 ... "https://api.openalex.org/works?search=${enc_kw}&per_page=50" 2>/dev/null)

# v6.4.5
local http_code
raw=$(curl -s -w "\n%{http_code}" --max-time 25 ... "https://api.openalex.org/works?search=${enc_kw}&per_page=50" 2>/dev/null)
http_code=$(echo "$raw" | tail -1)
raw=$(echo "$raw" | sed '$d')
if [ "$http_code" = "429" ] && echo "$raw" | grep -qi 'rate limit\|Insufficient budget\|prepaid'; then
    log "    OpenAlex 429 限额用尽，跳过后续重试"
    break
fi
```

**效果**：从 4×25s=100s 缩短到 1×25s=25s，节省 75s

---

### 问题 2：Guideline 30s 超时不够

**症状**：`[INFO] 指南检索超时，跳过`，始终无指南文献

**根因**：Guideline 搜索内部 3 个 API 串行执行（PubMed esearch + esummary + EuropePMC + OpenAlex），总耗时 ≈10-120s，但 dispatcher 只给 30s

**修复**：

| 改动 | 旧值 | 新值 | 原因 |
|------|------|------|------|
| PubMed esearch timeout | 30s | 10s | 正常 1-2s，30s 过大 |
| PubMed esummary timeout | 30s | 10s | 同上 |
| EuropePMC timeout | 30s | 10s | 正常 2-3s，30s 过大 |
| OpenAlex timeout | 30s | 10s | 429 时快速失败（~2s） |
| 等待超时 | 30s | 60s | 原来只够跑 1 个 API |

**时间线修复后**：
```
正常情况：2+2+1+3+2 = 10s   ← 60s 绰绰有余
API 慢速：5+5+1+5+5  = 21s  ← 60s 仍够
极端超时：30+30+1+30+10 = 101s ← 60s 跳过（不影响主检索）
```

---

## 修改文件

| 文件 | 改动 |
|------|------|
| `~/.a2a/bin/a2a-dispatcher` | 5 处修改（见下方 diff 摘要） |

### Diff 摘要

```diff
- # a2a-dispatcher v6.4.4 — 并发锁
+ # a2a-dispatcher v6.4.5 — OpenAlex 429 检测 + Guideline 超时优化 + 并发锁

# === 改动 1：主检索 OpenAlex 429 检测（第 858-867 行）===
- local raw=$(curl -s --max-time 25 ...)
+ local http_code
+ raw=$(curl -s -w "\n%{http_code}" --max-time 25 ...)
+ http_code=$(echo "$raw" | tail -1)
+ raw=$(echo "$raw" | sed '$d')
+ if [ "$http_code" = "429" ] && echo "$raw" | grep -qi 'rate limit\|Insufficient budget'; then
+     log "    OpenAlex 429 限额用尽，跳过后续重试"
+     break
+ fi

# === 改动 2-4：Guideline 内部 API timeout 30→10 ===
- resp = urllib.request.urlopen(req, timeout=30)   # PubMed esearch
- resp2 = urllib.request.urlopen(req2, timeout=30)  # PubMed esummary
- resp = urllib.request.urlopen(req, timeout=30)   # EuropePMC
+ resp = urllib.request.urlopen(req, timeout=10)
+ resp2 = urllib.request.urlopen(req2, timeout=10)
+ resp = urllib.request.urlopen(req, timeout=10)

- resp = urllib.request.urlopen(req, timeout=30)   # OpenAlex
+ resp = urllib.request.urlopen(req, timeout=10)

# === 改动 5：Guideline 等待超时 30→60 ===
- while [ $gw_wait -lt 30 ]; do
+ while [ $gw_wait -lt 60 ]; do
```

---

## 版本历史

| 版本 | 日期 | 核心改动 |
|------|------|---------|
| v6.4.5 | 2026-08-16 | OpenAlex 429 检测 + Guideline 超时优化 |
| v6.4.4 | 2026-08-16 | 并发锁（防止多实例同时运行） |
| v6.4 | 2026-08-14 | OpenAlex/PubMed 关键词逐步缩减重试 |
| v6.3 | 2026-08-14 | PMID 逐条验证 + 杠精审核 100 分制 |
| v6.2 | 2026-08-13 | 内容优先 + 全文验证 |
| v6.1 | 2026-08-12 | 10 路 API 验证通过 |

---

## 验证

- [x] `bash -n` 语法检查通过
- [x] 429 检测逻辑模拟测试通过
- [ ] 实际检索验证（等待用户下次触发）

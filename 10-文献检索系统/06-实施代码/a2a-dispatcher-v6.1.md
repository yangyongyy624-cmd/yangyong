---
type: 代码
version: v6.1
date: 2026-08-12
status: ✅ 已验证通过
---

# a2a-dispatcher v6.1 — 文献检索调度器（最终版）

> 最后修改：2026-08-12
> 位置：`~/.a2a/bin/a2a-dispatcher`
> 大小：1113 行 Bash
> 状态：✅ 8 路 API 全部验证通过

## 核心架构

```
用户输入 → Agent 0 (Obsidian) → 7路并行API → Unpaywall → Guideline → 去重评分 → 全文验证 → 透明度验证 → 输出
```

## 修复记录（v6.0 → v6.1）

| Bug | 修复 | 验证 |
|-----|------|------|
| PubMed 中文关键词 → 0 篇 | `en_kw="$openalex_kw"` + `sys.argv[1]` 传参 | ✅ 49 篇 |
| PMC 中文关键词 → 0 篇 | 改用 `$en_kw` | ✅ 20 篇 |
| Guideline 关键词提取失败 | 接收主函数 en_kw 作为第三参数 | ✅ 9+ 篇 |
| CrossRef 无被引次数 | 添加 `is-referenced-by-count` | ✅ |

## 10 路检索

| 路 | 名称 | 方式 | 关键词 | 结果 |
|---|------|------|--------|------|
| 0 | Obsidian 本地 | 阻塞 | 中文分词 | 59 篇 |
| 1 | OpenAlex | 并行 | 英文 | 49 篇 |
| 2 | CrossRef | 并行 | URL 编码 | 49 篇 |
| 3 | EuropePMC | 并行 | URL 编码 | 11 篇 |
| 4 | Semantic Scholar | 并行 | URL 编码 | ⚠️ 429 |
| 5 | PMC | 并行+sleep | 英文 ($en_kw) | 20 篇 |
| 6 | PubMed | 并行+sleep | 英文 (sys.argv) | 49 篇 |
| 7 | (等待) | — | — | — |
| 8 | Unpaywall | 串行 | — | 18 条 |
| 9 | Guideline | 串行 | 英文 ($en_kw) | 9+ 篇 |

## 评分模型

| 项目 | 最高分 | 标准 |
|------|--------|------|
| 期刊影响力 | 25 | Tier20=25, Tier15=15, Tier10=8 |
| 被引次数 | 20 | >500=20, >200=18, >100=15, >50=12, >20=10, >5=7 |
| 年份 | 10 | ≥2025=10, ≥2023=7, ≥2020=5, ≥2015=3 |
| 本地验证 | 5 | Obsidian 知识库已有 |
| 指南加成 | 5 | Guideline 来源 |

## 使用方式

```bash
a2a-dispatcher search "关键词"
```

## 输出目录

`/tmp/a2a_search_XXXXXX/` — 保留所有 API 原始输出，供透明度验证

## 敏感信息

无。仅使用公共 API，`email=research@a2a` 为 Unpaywall 公共标识。

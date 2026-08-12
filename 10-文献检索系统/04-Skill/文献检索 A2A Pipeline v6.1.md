---
type: skill
name: 文献检索 A2A Pipeline
version: v6.1
date: 2026-08-12
status: ✅ 已定型
---

# 文献检索 A2A Pipeline Skill v6.1

## 使用方法

```bash
# 唯一用法（禁止自己写脚本）
a2a-dispatcher search "临床关键词"
```

## 触发词

检索、查文献、搜索、找论文、找文章、PubMed、OpenAlex、CrossRef、Semantic Scholar、文献综述、文献报告、高分文献、核心期刊

## 10 路检索

| 路 | 名称 | 说明 |
|---|------|------|
| 0 | Obsidian 本地 | 59 篇已有知识库 |
| 1 | OpenAlex | 反向追踪，49 篇 |
| 2 | CrossRef | DOI 独有，含 Abstract |
| 3 | EuropePMC | 欧洲文献 |
| 4 | Semantic Scholar | 正向追踪（⚠️ 429 限流） |
| 5 | PMC | 免费全文 |
| 6 | PubMed | 临床文献核心库 |
| 8 | Unpaywall | OA 链接 |
| 9 | Guideline | 高被引经典（>100 次） |

## 输出

- `/tmp/a2a_search_XXXXXX/` — 所有 API 原始输出（保留供验证）
- 去重后 Top 100 排序
- 全文获取验证（Top 20 PMID）

## 评分

期刊(0-25) + 引用(0-20) + 年份(0-10) + 本地验证(0-5) + 指南加成(0-5) = **满分 65**

## 验证

- dispatcher 输出存在
- PMID 可追溯到 API 输出
- 禁止编造检索数字

## 相关文件

- [[a2a-dispatcher-v6.1]] — 调度器代码
- [[文献检索流水线 v6.1-AtoA报告]] — A-to-A 验证报告
- [[00-主索引]] — 文献检索系统总索引

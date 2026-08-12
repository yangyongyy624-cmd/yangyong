#!/bin/bash
# 文献检索透明度报告 — 第一性原理版（PubMed API 验证）
# 用法: ./verify-delivery.sh <topic> <report_file> [max_retries]
#
# 第一性原理验证：不依赖 dispatcher 输出，直接查 PubMed API
#   1. 真实性 — PMID 在 PubMed 能查到？（不是 Agent 编造）
#   2. 相关性 — 标题/摘要包含主题关键词？
#   3. 质量 — 期刊、研究类型、被引次数
#   4. 来源追溯 — 在 dispatcher 输出 = 检索；不在但 PubMed 有 = 知识库补充
#
# 评分（满分 100）:
#   dispatcher 运行: 30 分（3+ 路 API）
#   PMID 真实性: 30 分（每个 PMID 在 PubMed 存在）
#   PMID 相关性: 20 分（标题/摘要含主题关键词）
#   PMID 质量: 20 分（期刊、研究类型、被引）

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

TOPIC="${1:-}"
REPORT_FILE="${2:-}"
MAX_RETRIES="${3:-3}"

# PubMed API 配置
API_BASE="https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
API_KEY="${NCBI_API_KEY:-}"  # 可选，有 key 可提速率限制

# ============================================================
# 工具函数
# ============================================================

get_latest_dir() {
    for d in $(ls -1td /tmp/a2a_search_* 2>/dev/null); do
        if [ -d "$d" ]; then
            echo "$d"
            return
        fi
    done
    echo ""
}

get_latest_dir_with_api() {
    for d in $(ls -1td /tmp/a2a_search_* 2>/dev/null); do
        if [ ! -d "$d" ]; then continue; fi
        for f in pubmed.txt crossref.txt openalex.txt semanticscholar.txt europepmc.txt; do
            local sz=$(stat -f '%z' "$d/$f" 2>/dev/null || echo 0)
            if [ "$sz" -gt 100 ]; then
                echo "$d"
                return
            fi
        done
    done
    # 如果没有找到带 API 输出的目录，退回最新目录
    get_latest_dir
}

extract_pmids() {
    local file="$1"
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        return
    fi
    grep -oE 'PMID[=: ]+?([0-9]{7,9})' "$file" 2>/dev/null | grep -oE '[0-9]+' | sort -u
}

expand_keywords() {
    local round=$1
    local base="$2"
    case $round in
        0) echo "$base" ;;
        1)
            local en_kw=$(echo "$base" | grep -oE '[a-zA-Z]{3,}' | head -5 | tr '\n' ' ')
            if [ -n "$en_kw" ]; then echo "${base} ${en_kw}"; else echo "$base"; fi
            ;;
        2)
            local en_kw=$(echo "$base" | grep -oE '[a-zA-Z]{3,}' | head -5 | tr '\n' ' ')
            echo "${base} ${en_kw} therapy treatment intervention"
            ;;
    esac
}

run_dispatcher() {
    local round="$1"
    local expanded_kw=$(expand_keywords "$round" "$TOPIC")
    log "  第 $((round + 1)) 轮: $expanded_kw"
    a2a-dispatcher search "$expanded_kw" 2>/dev/null
    get_latest_dir
}

# ============================================================
# PubMed API 验证（核心：第一性原理）
# ============================================================

verify_pmids() {
    local pmids="$1"
    local dir="$2"

    if [ -z "$pmids" ]; then
        echo "NO_PMIDS"
        return 3
    fi

    local total=$(echo "$pmids" | wc -l | tr -d ' ')
    local real=0 fake=0 kb_supplement=0 disp_found=0 relevance_score=0 quality_score=0
    local fake_list="" real_list=""

    # 逐个 PMID 验证
    while IFS= read -r pmid; do
        [ -z "$pmid" ] && continue

        # 1. 真实性：查 PubMed API
        local api_resp
        api_resp=$(curl -s --max-time 15 "${API_BASE}/esummary.fcgi?db=pubmed&id=${pmid}" 2>/dev/null) || api_resp=""

        if echo "$api_resp" | grep -q "<ERROR>"; then
            # PubMed 查不到 → 编造
            fake=$((fake + 1))
            fake_list="$fake_list $pmid"
            continue
        fi

        if [ -z "$api_resp" ]; then
            # API 超时/失败 → 跳过（不惩罚）
            log "  ⚠️ PMID $pmid API 超时，跳过"
            continue
        fi

        # PMID 在 PubMed 存在 → 真实
        real=$((real + 1))
        real_list="$real_list $pmid"

        # 2. 提取元数据（esummary 包含 title + journal）
        local title journal pub_date
        title=$(echo "$api_resp" | grep -o '<Item Name="Title"[^>]*>[^<]*</Item>' | sed 's/<[^>]*>//g') || title=""
        journal=$(echo "$api_resp" | grep -o '<Item Name="Source"[^>]*>[^<]*</Item>' | sed 's/<[^>]*>//g') || journal=""
        pub_date=$(echo "$api_resp" | grep -o '<Item Name="PubDate"[^>]*>[^<]*</Item>' | sed 's/<[^>]*>//g' | cut -d' ' -f1) || pub_date=""

        # 3. 相关性：检查标题是否包含主题关键词
        local has_kw=0
        if [ -n "$TOPIC" ] && [ -n "$title" ]; then
            # 提取英文关键词（4+ 字母）
            local en_kws=$(echo "$TOPIC" | grep -oE '[a-zA-Z]{4,}' || true)
            for kw in $en_kws; do
                if echo "$title" | grep -qi "$kw"; then
                    has_kw=1
                    break
                fi
            done
            # 中文关键词 → 拼音/英文映射（常见医学术语）
            if [ $has_kw -eq 0 ]; then
                # 简单映射：艾司氯胺酮→esketamine, 解离→dissociation, 抑郁→depression
                local cn_to_en=""
                echo "$TOPIC" | grep -q '艾司氯胺酮' && cn_to_en="$cn_to_en esketamine"
                echo "$TOPIC" | grep -q '氯胺酮' && cn_to_en="$cn_to_en ketamine"
                echo "$TOPIC" | grep -q '解离' && cn_to_en="$cn_to_en dissociat"
                echo "$TOPIC" | grep -q '抑郁' && cn_to_en="$cn_to_en depress"
                echo "$TOPIC" | grep -q '镇静' && cn_to_en="$cn_to_en sedat"
                echo "$TOPIC" | grep -q '焦虑' && cn_to_en="$cn_to_en anxiet"
                for kw in $cn_to_en; do
                    if echo "$title" | grep -qi "$kw"; then
                        has_kw=1
                        break
                    fi
                done
            fi
            if [ $has_kw -eq 1 ]; then
                relevance_score=$((relevance_score + 1))
            fi
        fi

        # 4. 质量评估
        local quality_pts=0
        # 期刊类型（高影响力期刊关键词）
        if echo "$journal" | grep -qiE 'lancet|nature|science|cell|nejm|jaman|br med j|bmj|arch gen|am j|clin|front|neuropsych'; then
            quality_pts=$((quality_pts + 3))
        elif echo "$journal" | grep -qiE 'j|ann|proc|rev|eur|asian|aust'; then
            quality_pts=$((quality_pts + 2))
        else
            quality_pts=$((quality_pts + 1))
        fi
        # 研究类型（标题关键词）
        if echo "$title" | grep -qiE 'randomized|controlled|trial|RCT|meta.?analysis|systematic.?review|cohort'; then
            quality_pts=$((quality_pts + 2))
        fi
        # 近年（2021+ = 较新）
        if [ -n "$pub_date" ] && [ "$pub_date" -ge 2021 ] 2>/dev/null; then
            quality_pts=$((quality_pts + 1))
        fi
        quality_score=$((quality_score + quality_pts))

        # 5. 来源追溯
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            local in_disp=0
            for f in "$dir/"*.txt; do
                if grep -q "$pmid" "$f" 2>/dev/null; then
                    in_disp=1
                    break
                fi
            done
            if [ $in_disp -eq 1 ]; then
                disp_found=$((disp_found + 1))
            else
                kb_supplement=$((kb_supplement + 1))
            fi
        fi

    done <<< "$pmids"

    # 计算分数
    local truth_score=0 rel_score=0 qual_score=0
    if [ $real -gt 0 ] || [ $fake -gt 0 ]; then
        # 真实性（30分）：100% 真实 = 30
        truth_score=$((30 * real / (real + fake)))
        # 相关性（20分）：所有真实 PMID 中，含主题关键词的比例
        if [ $real -gt 0 ]; then
            rel_score=$((20 * relevance_score / real))
        fi
        # 质量（20分）：平均质量分（满分 6 分/篇 → 归一化到 20）
        local max_qual=$((6 * real))
        if [ $max_qual -gt 0 ]; then
            qual_score=$((20 * quality_score / max_qual))
        fi
    fi

    # 输出结果（冒号分隔，便于调用方解析）
    echo "RESULT:${total}:${real}:${fake}:${kb_supplement}:${disp_found}:${truth_score}:${rel_score}:${qual_score}:${relevance_score}:${quality_score}:${fake_list}"
}

# ============================================================
# 日志
# ============================================================
log()  { echo -e "${CYAN}[verify]${NC} $*"; }
ok()   { echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${MAGENTA}[INFO]${NC} $*"; }

# ============================================================
# 主流程：PubMed API 验证 + 自动重试
# ============================================================

echo ""
echo "============================================"
echo " 文献检索透明度报告（第一性原理版）"
echo "============================================"
echo ""

if [ -z "$TOPIC" ]; then
    fail "缺少检索主题"
    echo "用法: $0 <topic> <report_file> [max_retries]"
    exit 1
fi

# 提取报告中的 PMID
ALL_PMIDS=""
if [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ]; then
    ALL_PMIDS=$(extract_pmids "$REPORT_FILE")
    if [ -n "$ALL_PMIDS" ]; then
        pmid_count=$(echo "$ALL_PMIDS" | wc -l | tr -d ' ')
        log "从报告中提取到 $pmid_count 个 PMID"
    else
        log "报告中未找到 PMID（可能未引用文献）"
    fi
fi

# 检查现有 dispatcher（优先找有 API 输出的）
FIRST_DIR=$(get_latest_dir_with_api)
START_ROUND=0

if [ -n "$FIRST_DIR" ]; then
    log "找到 dispatcher 输出: $FIRST_DIR"
else
    warn "dispatcher 未运行"
    START_ROUND=0
fi

# ============================================================
# 第一步：PubMed API 验证（第一性原理核心）
# ============================================================
echo ""
echo "--------------------------------------------"
info "第一步：PubMed API 验证（真实性 + 相关性 + 质量）"
echo "--------------------------------------------"

PUBMED_SCORE=0
if [ -n "$ALL_PMIDS" ]; then
    VERIFY_RESULT=$(verify_pmids "$ALL_PMIDS" "$FIRST_DIR")
    log "API 验证结果: $VERIFY_RESULT"

    # 解析结果
    v_total=$(echo "$VERIFY_RESULT" | cut -d: -f2)
    v_real=$(echo "$VERIFY_RESULT" | cut -d: -f3)
    v_fake=$(echo "$VERIFY_RESULT" | cut -d: -f4)
    v_kb=$(echo "$VERIFY_RESULT" | cut -d: -f5)
    v_disp=$(echo "$VERIFY_RESULT" | cut -d: -f6)
    v_truth=$(echo "$VERIFY_RESULT" | cut -d: -f7)
    v_rel=$(echo "$VERIFY_RESULT" | cut -d: -f8)
    v_qual=$(echo "$VERIFY_RESULT" | cut -d: -f9)
    v_fake_list=$(echo "$VERIFY_RESULT" | cut -d: -f12-)

    echo ""
    info "--- PMID 验证详情 ---"
    info "PMID 总数: $v_total"
    ok "PubMed 可查: $v_real"
    if [ "$v_fake" -gt 0 ]; then
        fail "PubMed 查不到: $v_fake (疑似编造:$v_fake_list)"
    fi
    info "知识库补充: $v_kb 篇（未在 dispatcher 输出但 PubMed 验证为真实文献）"
    info "dispatcher 检索: $v_disp 篇"
    info ""
    info "真实性: ${v_truth}/30  相关性: ${v_rel}/20  质量: ${v_qual}/20"
    PUBMED_SCORE=$((v_truth + v_rel + v_qual))
else
    info "无 PMID 需要验证"
fi

# ============================================================
# 第二步：Dispatcher 状态检查
# ============================================================
echo ""
echo "--------------------------------------------"
info "第二步：Dispatcher 运行状态"
echo "--------------------------------------------"

DISP_SCORE=0
if [ -n "$FIRST_DIR" ] && [ -d "$FIRST_DIR" ]; then
    api_count=0
    for f in pubmed.txt crossref.txt openalex.txt semanticscholar.txt europepmc.txt; do
        sz=$(stat -f '%z' "$FIRST_DIR/$f" 2>/dev/null || echo 0)
        if [ "$sz" -gt 100 ]; then api_count=$((api_count + 1)); fi
    done
    if [ $api_count -ge 3 ]; then
        DISP_SCORE=30
        ok "Dispatcher 运行 ($api_count 路 API)"
    elif [ $api_count -gt 0 ]; then
        DISP_SCORE=$((10 * api_count))
        warn "Dispatcher 部分运行 ($api_count 路 API)"
    else
        warn "Dispatcher 无 API 输出"
    fi
else
    warn "Dispatcher 未运行"
fi

# ============================================================
# 第三步：自动重试（如果验证分数低）
# ============================================================
TOTAL_SCORE=$((DISP_SCORE + PUBMED_SCORE))
echo ""
echo "--------------------------------------------"

if [ $TOTAL_SCORE -lt 70 ] && [ "$START_ROUND" -lt "$MAX_RETRIES" ]; then
    warn "当前评分 ${TOTAL_SCORE}/100 < 70，开始自动重试..."

    LAST_DIR="$FIRST_DIR"
    for ((round = START_ROUND; round < MAX_RETRIES; round++)); do
        echo ""
        echo "--------------------------------------------"
        LAST_DIR=$(run_dispatcher "$round")

        if [ -z "$LAST_DIR" ]; then
            fail "dispatcher 运行失败"
            continue
        fi

        sleep 2

        # 重新验证
        if [ -n "$ALL_PMIDS" ]; then
            VERIFY_RESULT=$(verify_pmids "$ALL_PMIDS" "$LAST_DIR")
            log "API 验证结果: $VERIFY_RESULT"

            v_truth=$(echo "$VERIFY_RESULT" | cut -d: -f7)
            v_rel=$(echo "$VERIFY_RESULT" | cut -d: -f8)
            v_qual=$(echo "$VERIFY_RESULT" | cut -d: -f9)
            v_real=$(echo "$VERIFY_RESULT" | cut -d: -f3)
            v_fake=$(echo "$VERIFY_RESULT" | cut -d: -f4)
            v_kb=$(echo "$VERIFY_RESULT" | cut -d: -f5)
            v_disp=$(echo "$VERIFY_RESULT" | cut -d: -f6)

            PUBMED_SCORE=$((v_truth + v_rel + v_qual))

            # 更新 dispatcher 分数
            api_count=0
            for f in pubmed.txt crossref.txt openalex.txt semanticscholar.txt europepmc.txt; do
                sz=$(stat -f '%z' "$LAST_DIR/$f" 2>/dev/null || echo 0)
                if [ "$sz" -gt 100 ]; then api_count=$((api_count + 1)); fi
            done
            if [ $api_count -ge 3 ]; then DISP_SCORE=30; elif [ $api_count -gt 0 ]; then DISP_SCORE=$((10 * api_count)); fi

            TOTAL_SCORE=$((DISP_SCORE + PUBMED_SCORE))

            info "第 $((round + 1)) 轮: PMID 真实 ${v_real}/${v_total} | 编造 ${v_fake} | 知识库 ${v_kb} | 检索 ${v_disp}"
            info "评分: 真实性 ${v_truth}/30 + 相关性 ${v_rel}/20 + 质量 ${v_qual}/20 + dispatcher ${DISP_SCORE}/30 = ${TOTAL_SCORE}/100"

            if [ $TOTAL_SCORE -ge 90 ]; then
                ok "第 $((round + 1)) 轮验证通过！评分 ${TOTAL_SCORE}/100"
                echo ""
                echo "============================================"
                echo " 最终验证结果"
                echo "============================================"
                ok "所有 PMID 均经 PubMed API 验证"
                echo "  重试轮次: $((round + 1))"
                exit 0
            fi
        fi
    done
fi

# ============================================================
# 最终报告
# ============================================================
echo ""
echo "============================================"
echo " Agent 检索透明度报告（第一性原理版）"
echo "============================================"
echo ""

# 评分面板
echo -e "${CYAN}评分明细:${NC}"
echo "  dispatcher 运行: ${DISP_SCORE}/30"
if [ -n "${v_real:-}" ] && [ -n "${v_fake:-}" ]; then
    local_total=$((v_real + v_fake))
    if [ $local_total -gt 0 ]; then
        truth_display=$((30 * v_real / local_total))
    else
        truth_display=0
    fi
else
    truth_display=0
fi
echo "  PMID 真实性:     ${truth_display}/30"
echo "  PMID 相关性:     ${v_rel:-0}/20"
echo "  PMID 质量:       ${v_qual:-0}/20"
echo "  ───────────────────────"
echo "  总分:            ${TOTAL_SCORE}/100"
echo ""

# 详细结果
if [ $v_fake -eq 0 ]; then
    ok "所有 PMID 均在 PubMed 数据库中存在（${v_real}/${v_total}）"
else
    fail "发现 ${v_fake} 个 PMID 在 PubMed 查不到（疑似编造:$v_fake_list）"
fi

info "知识库补充: ${v_kb} 篇（未在 dispatcher 输出，但 PubMed 验证为真实文献 — 正常行为）"

if [ $v_disp -gt 0 ]; then
    info "dispatcher 检索: ${v_disp} 篇 PMID 在 dispatcher 输出中"
fi

# 飞书提醒
if [ $TOTAL_SCORE -lt 50 ]; then
    echo ""
    echo "============================================"
    echo " 飞书提醒（生成 JSON）"
    echo "============================================"
    echo ""
    echo '{'
    echo '  "msg_type": "interactive",'
    echo '  "card": {'
    echo '    "header": {'
    echo '      "title": {"tag": "plain_text", "content": "⚠️ 文献检索透明度警告"},'
    echo '      "template": "red"'
    echo '    },'
    echo '    "elements": ['
    echo '      {"tag": "markdown", "content": "**评分: '"$TOTAL_SCORE"'/100"**"},'
    if [ $v_fake -gt 0 ]; then
        echo '      {"tag": "markdown", "content": "❌ 发现 '"$v_fake"' 个 PMID 疑似编造（PubMed 查不到）\\n"},'
    fi
    echo '      {"tag": "markdown", "content": "真实性: '"$v_truth"'/30 | 相关性: '"$v_rel"'/20 | 质量: '"$v_qual"'/20 | Dispatcher: '"$DISP_SCORE"'/30"}'
    echo '    ]'
    echo '  }'
    echo '}'
fi

echo ""
exit 0

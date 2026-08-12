#!/bin/bash
# a2a-dispatcher v6.0 — Agent 0 本地 + 军事医学图书馆全文验证
set -euo pipefail
A2A_HOME="${A2A_HOME:-$HOME/.a2a}"
A2A="$A2A_HOME/bin/a2a"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${CYAN}[dispatcher]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC} $*"; }
warn(){ echo -e "${YELLOW}[warn]${NC} $*"; }

OBSIDIAN="${OBSIDIAN_VAULT:-$HOME/Documents/Obsidian Vault}"

search_api() {
    local name="$1" url="$2" parser="$3" output="$4"
    log "  📡 $name 检索中..."
    (
        local raw=$(curl -s --max-time 30 -H "User-Agent: A2A-Dispatcher/2.0" "$url" 2>/dev/null)
        local code=$?
        if [ $code -ne 0 ]; then
            echo "[ERROR] $name curl 失败 (exit $code)" > "$output"
            exit 1
        fi
        # 检查 HTTP 错误响应（429 等）
        if echo "$raw" | grep -qi 'Too Many Requests'; then
            echo "[ERROR] $name 被限流 (HTTP 429)" > "$output"
            exit 1
        fi
        if [ -z "$raw" ]; then
            echo "[ERROR] $name 返回空" > "$output"
            exit 1
        fi
        echo "$raw" | python3 -c "$parser" 2>/dev/null > "$output"
        # 如果 parser 失败，写原始错误
        if [ ! -s "$output" ]; then
            echo "[ERROR] $name parser 失败" > "$output"
        fi
    ) 2>/dev/null &
}

# ===== Agent 0: 本地 Obsidian 知识库检索 =====
search_local_obsidian() {
    local topic="$1"
    local tmpdir="$2"
    log "  💾 Agent 0: 本地 Obsidian 知识库检索..."

    python3 - "$topic" "$OBSIDIAN" "$tmpdir" << 'PYEOF'
import sys, os, re, json, hashlib
from datetime import datetime

topic = sys.argv[1]
vault = sys.argv[2]
tmpdir = sys.argv[3]

# 关键词预处理：中文分词 + 英文拆分
keywords = set()
# 中文关键词（按空格/逗号/顿号拆分）
cn_kw = [k.strip() for k in re.split(r'[，,、\s]+', topic) if len(k.strip()) >= 2]
keywords.update(cn_kw)
# 英文关键词（小写）
en_kw = [k.lower().strip() for k in re.split(r'[\s_]+', topic) if len(k.strip()) >= 3]
keywords.update(en_kw)

if not keywords:
    keywords = {topic.lower().strip()}

print(f"  [Agent0] 关键词: {sorted(keywords)}", file=sys.stderr)

# ===== 1. 搜索匹配的文件 =====
matched_files = []
for root, dirs, files in os.walk(vault):
    # 跳过隐藏目录和 .git
    dirs[:] = [d for d in dirs if not d.startswith('.')]
    for f in files:
        if not f.endswith('.md'):
            continue
        fpath = os.path.join(root, f)
        try:
            with open(fpath, 'r', encoding='utf-8') as fh:
                content = fh.read()
        except:
            continue
        # 标题和正文关键词匹配
        fname = f.replace('.md', '').lower()
        c_lower = content.lower()
        match_score = 0
        for kw in keywords:
            kw_lower = kw.lower()
            if kw_lower in fname:
                match_score += 10
            if kw_lower in c_lower:
                match_score += c_lower.count(kw_lower)
        if match_score > 0:
            matched_files.append((fpath, match_score, fname))

matched_files.sort(key=lambda x: x[1], reverse=True)
print(f"  [Agent0] 匹配到 {len(matched_files)} 个文件", file=sys.stderr)

# ===== 2. 解析文献数据 =====
# 支持的表格格式：
# | 编号 | 文献 | 期刊/年份 | 核心剂量 | 标签 |
# | | Title | Journal | Year | Cited | ... |
papers = []
reading_reports = []

def extract_pmid(text):
    """提取 PMID"""
    m = re.findall(r'PMID[=:\s]*(\d+)', text, re.IGNORECASE)
    return [p.strip() for p in m if p.strip()]

def extract_doi(text):
    """提取 DOI"""
    m = re.findall(r'(10\.\d+/[^\s<>"\')\]]+)', text)
    return [d.strip() for d in m if d.strip()]

def extract_year(text):
    """提取年份"""
    m = re.findall(r'(20[0-2][0-9])', text)
    return m[-1] if m else ''

def extract_journal(text):
    """提取期刊名（常见顶刊识别）"""
    journal_map = {
        'nejm': 'N Engl J Med',
        'new engl j med': 'N Engl J Med',
        'lancet': 'Lancet',
        'jama': 'JAMA',
        'nature': 'Nature',
        'science': 'Science',
        'bmj': 'BMJ',
        'cell': 'Cell',
        'am j psychiatry': 'Am J Psychiatry',
        'world psychiatry': 'World Psychiatry',
        'mol psychiatry': 'Mol Psychiatry',
        'neuropsychopharmacol': 'Neuropsychopharmacology',
        'jaacap': 'JAACAP',
        'jclinpsychiatry': 'J Clin Psychiatry',
        'j psychiatr res': 'J Psychiatr Res',
        'biol psychiatry': 'Biol Psychiatry',
        'ann intern med': 'Ann Intern Med',
        'br j anaesth': 'Br J Anaesth',
        'anaesthesia': 'Anaesthesia',
        'intensive care med': 'Intensive Care Med',
        'crit care': 'Crit Care',
        'j clin anesth': 'J Clin Anesth',
    }
    text_lower = text.lower()
    for key, val in journal_map.items():
        if key in text_lower:
            return val
    # 通用：查找括号中的期刊名
    m = re.findall(r'\(([^)]*(?:j|med|psychiatry|anaesth|sci)[^)]*)\)', text_lower)
    if m:
        return m[0][:50]
    return ''

def parse_markdown_table(content):
    """解析 Markdown 表格"""
    rows = []
    in_table = False
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('|') and line.endswith('|'):
            cells = [c.strip() for c in line.split('|')[1:-1]]
            if in_table or not any('-' in c for c in cells):
                rows.append(cells)
                in_table = True
            elif any('-' in c for c in cells):
                in_table = True  # separator line
    return rows

for fpath, score, fname in matched_files[:50]:  # 最多处理 50 个文件
    try:
        with open(fpath, 'r', encoding='utf-8') as fh:
            content = fh.read()
    except:
        continue

    # 提取 PMID
    pmids = extract_pmid(content)
    dois = extract_doi(content)

    # 提取文献条目（从表格）
    rows = parse_markdown_table(content)

    # 如果是索引文件，提取文献信息
    is_index = any(kw in fname.lower() for kw in ['索引', 'index', '00-'])

    if is_index and rows:
        # 索引文件：提取表头和数据行
        header = rows[0] if rows else []
        # 查找相关列
        title_col = None
        journal_col = None
        year_col = None
        tag_col = None
        for i, h in enumerate(header):
            h_lower = h.lower()
            if any(k in h_lower for k in ['文献', '标题', 'title', '名称']):
                title_col = i
            if any(k in h_lower for k in ['期刊', 'journal', 'journ']):
                journal_col = i
            if any(k in h_lower for k in ['年份', 'year', 'date']):
                year_col = i
            if any(k in h_lower for k in ['标签', 'tag', '证据']):
                tag_col = i

        # 解析数据行（跳过分隔符行）
        for row in rows[1:]:
            if any('-' in c for c in row):
                continue
            title = row[title_col] if title_col is not None and title_col < len(row) else ''
            journal = row[journal_col] if journal_col is not None and journal_col < len(row) else ''
            year = row[year_col] if year_col is not None and year_col < len(row) else ''
            tags = row[tag_col] if tag_col is not None and tag_col < len(row) else ''

            # 清理标题（移除 [[wiki-link]] 格式）
            title = re.sub(r'\[\[([^\]|]+)\]\]', r'\1', title).strip()
            if not title or len(title) < 5:
                continue

            # 从期刊列提取年份
            if not year:
                year = extract_year(journal)
            if not year:
                year = extract_year(title)

            # 判断证据等级
            cited = 0
            if any(k in tags for k in ['#一区TOP', '#一区', 'Level 1', 'RCT', 'Meta']):
                cited = 50  # 标记为高被引
            elif any(k in tags for k in ['#二区', '#三区', '队列', '病例对照']):
                cited = 10

            # 提取 PMID（从标题或标签中）
            file_pmids = extract_pmid(title + ' ' + journal + ' ' + tags)
            pmid = file_pmids[0] if file_pmids else ''

            # 提取 journal 名
            jn = extract_journal(journal + ' ' + title)

            # 文件路径（用于全文验证）
            rel_path = os.path.relpath(fpath, vault)

            papers.append({
                'source': 'Local',
                'title': title[:120],
                'doi': dois[0] if dois else '',
                'pmid': pmid,
                'year': year[:4] if year else '',
                'cited': cited,
                'journal': jn or journal[:50],
                'local_path': rel_path,
                'tags': tags[:100],
                'is_local': True,
            })

        # 提取阅读报告
        if '读书报告' in fpath or '阅读报告' in fpath or '综述' in fpath:
            reading_reports.append({
                'file': fname,
                'path': os.path.relpath(fpath, vault),
                'score': score,
            })

    # 非索引文件：直接提取 PMID + 标题
    elif pmids or dois:
        # 从文件名提取标题
        title = fname.replace('_', ' ').strip()
        # 取正文前 200 字符作为摘要
        body = content[:500].replace('\n', ' ').strip()
        year = extract_year(content[:200])
        jn = extract_journal(content[:500])

        for pmid in pmids[:3]:  # 最多 3 个 PMID
            papers.append({
                'source': 'Local',
                'title': title[:120],
                'doi': dois[0] if dois else '',
                'pmid': str(pmid),
                'year': year[:4] if year else '',
                'cited': 20,  # 本地已有的文献默认中等被引
                'journal': jn or '',
                'local_path': os.path.relpath(fpath, vault),
                'tags': '',
                'is_local': True,
            })

    elif score >= 20:
        # 高匹配度的文件，即使没有 PMID 也收录
        title = fname.replace('_', ' ').strip()[:120]
        body = content[:200].replace('\n', ' ').strip()
        year = extract_year(content[:200])
        jn = extract_journal(content[:300])

        # 提取 PMID
        file_pmids = extract_pmid(content[:500])
        for pmid in file_pmids[:1]:
            papers.append({
                'source': 'Local',
                'title': title,
                'doi': '',
                'pmid': str(pmid),
                'year': year[:4] if year else '',
                'cited': 10,
                'journal': jn or '',
                'local_path': os.path.relpath(fpath, vault),
                'tags': '',
                'is_local': True,
            })

# ===== 3. 输出 =====
print()
print('=' * 60)
print(f'  💾 Agent 0: 本地 Obsidian 知识库检索')
print('=' * 60)
print()

if papers:
    print(f'## 📚 本地知识库匹配 ({len(papers)} 篇)')
    print()
    for i, p in enumerate(papers):
        pm = p.get('pmid', '')
        t = p.get('title', '')[:80]
        j = p.get('journal', '')
        y = p.get('year', '')
        path = p.get('local_path', '')
        tags = p.get('tags', '')
        marker = '🔵' if pm else '🟢'
        print(f'{marker} #{i+1} {t}')
        if pm: print(f'  PMID: {pm} | 期刊: {j} | 年份: {y}')
        else: print(f'  期刊: {j} | 年份: {y}')
        print(f'  📁 {path}')
        if tags: print(f'  标签: {tags}')
        print()
else:
    print('  ⚪ 本地知识库未找到直接匹配的文献')
    print()

if reading_reports:
    print(f'## 📖 本地阅读报告 ({len(reading_reports)} 份)')
    print()
    for r in reading_reports[:10]:
        print(f'**📄 {r["file"]}**')
        print(f'  路径: `{r["path"]}`')
        print()

# ===== 4. 输出纯 PMID 列表（供后续全文验证） =====
all_pmids = [p['pmid'] for p in papers if p.get('pmid')]
local_pmid_file = os.path.join(tmpdir, 'obsidian_pmids.txt')
with open(local_pmid_file, 'w') as f:
    f.write(','.join(all_pmids))

# ===== 5. 输出文献数据（供 dedup 合并）=====
output_file = os.path.join(tmpdir, 'obsidian.txt')
with open(output_file, 'w', encoding='utf-8') as f:
    for p in papers:
        line = f"[Local] Title={p['title']} DOI={p['doi']} PMID={p['pmid']} Year={p['year']} Cited={p['cited']} Journal={p['journal']}"
        f.write(line + '\n')

print()
print(f'  ✅ Agent 0 完成: {len(papers)} 篇本地文献 + {len(reading_reports)} 份阅读报告')
print(f'  💾 PMID 列表: {len(all_pmids)} 个')
PYEOF
}

deduplicate_and_score() {
    local tmpdir="$1"
    local all_raw="$tmpdir/all_raw.txt"
    # 过滤掉错误标记行（-h 避免带文件名前缀）
    grep -hv '^\[ERROR\]' "$tmpdir"/*.txt > "$all_raw" 2>/dev/null || true

    # 统计来源分布
    local sources=$(awk -F'[][]' '{print $2}' "$all_raw" | sort | uniq -c | sort -rn)
    local obsidian_pmids=""
    [ -f "$tmpdir/obsidian_pmids.txt" ] && obsidian_pmids=$(cat "$tmpdir/obsidian_pmids.txt")

    python3 - "$all_raw" "$obsidian_pmids" << 'PYEOF'
import json, sys, re
all_raw = sys.argv[1]
obsidian_pmids_str = sys.argv[2] if len(sys.argv) > 1 else ""
obsidian_pmids = set(obsidian_pmids_str.split(',')) if obsidian_pmids_str else set()

papers = []
for line in open(all_raw, encoding='utf-8'):
    line = line.strip()
    if not line or not line.startswith('['): continue
    m = re.match(r'\[(\w+)\]\s+(.*)', line)
    if not m: continue
    api, rest = m.group(1), m.group(2)
    p = {'source': api}
    for k in ['Title','DOI','PMID','Year','Cited','Journal','Abstract']:
        pat = k + r'=(.*?)(?=\s+(?:Title|DOI|PMID|Year|Cited|Journal|Abstract|Source)=|\$)'
        val = re.search(pat, rest)
        p[k.lower()] = val.group(1) if val else ''
    papers.append(p)

seen_dois = set(); seen_pmid = set(); seen_titles = set()
unique = []
for p in papers:
    doi = p.get('doi','').lower().strip()
    pmid = p.get('pmid','').strip()
    title = p.get('title','').lower().strip()

    is_dup = False
    if doi and doi in seen_dois: is_dup = True
    if pmid and pmid in seen_pmid: is_dup = True

    if is_dup:
        continue

    if title and title in seen_titles:
        continue

    # 过滤公开数据集/非论文条目
    title_lower = title.lower().strip()
    if any(kw in title_lower for kw in ['encsr', 'screening assay', 'bioassay', 'reference standard']):
        continue

    seen_dois.add(doi) if doi else None
    seen_pmid.add(pmid) if pmid else None
    seen_titles.add(title) if title else None
    unique.append(p)

# 本地文献标记优化：本地已有的 PMID 标记为已验证
# Guideline 标记：来自指南/共识检索的文献
for p in unique:
    pmid = p.get('pmid','').strip()
    source = p.get('source','')
    if pmid in obsidian_pmids:
        p['is_local_verified'] = True
    else:
        p['is_local_verified'] = False
    if source == 'Guideline':
        p['is_guideline'] = True
    else:
        p['is_guideline'] = False

for p in unique:
    score = 0
    cited = int(p.get('cited','0') or 0)
    year = p.get('year','')
    jn = p.get('journal','').lower()

    # ===== 1. 期刊影响力 (最高 25 分) =====
    # Tier 20 — IF>20 (顶刊)
    tier20 = ['nejm','new engl j med','new england j med','lancet','jama','nature','science','bmj',
              'ann intern med','br med bull','proc natl acad sci','sci transl med',
              'cell','nat biotechnol','nat gen','nat struct mol biol','nat rev drug discov',
              'nat med','nat neurosci','nat methods','nat chem','nat biomed eng']
    # Tier 15 — IF>10 (权威期刊)
    tier15 = ['anesthesiology','british j anaesth','br j anaesth','bjja','anaesthesia','anaesth analg',
              'intensive care med','intensive care medicine','crit care','critical care',
              'crit care med','critical care medicine','paul med','paediatr anaesth','reg anaesth',
              'jama psych','jama psychiatry','mol psychiatry','am j psychiatry','ajp psychiatry',
              'world psychiatry','biol psychiatry','biol psychiat cogn neurosci',
              'neuropsychopharmacol','neuropsychopharmacology','br j psychiatry','bjp psychiatry',
              'lam', 'lancet psychiatry','lancet neurol','lancet glob health',
              'sci adv','sci transl med', 'eur neuropsychopharmacol',
              'j neurosci','j clin invest','blood','cancer cell']
    # Tier 10 — IF>5 (高质量期刊)
    tier10 = ['j clin anesth','j clin anesth','j cardiothorac','j cardiovasc',
              'eur j anaesthesiol','eur j anaesth','eu j anaesth','acta anaesthesiol',
              'minerva anestesiol','bja open','j pain','pain','shock','anaesth critical care',
              'j a affect disord','j affect disord','depress anxiet','depress anxiety',
              'j psychiatr res','j psychiatry neurosci','psychol med','psychol bull',
              'brain stim','brain stimulat','clin neurophysiol','clin neurophys pract',
              'eur arch psychiatry clin neurosci','prog neuropsychopharmacol biol psychiatry',
              'tranl psychiatry','transl psychiatry','mol neuropsychiatry']

    if any(t in jn for t in tier20):
        score += 25
    elif any(t in jn for t in tier15):
        score += 15
    elif any(t in jn for t in tier10):
        score += 8

    # 本地已验证文献额外加分
    if p.get('is_local_verified'):
        score += 5

    # 指南/共识文献额外加分（专家级可信度）
    if p.get('is_guideline'):
        score += 5

    # ===== 2. 被引次数 (最高 20 分) =====
    if cited > 500: score += 20
    elif cited > 200: score += 18
    elif cited > 100: score += 15
    elif cited > 50: score += 12
    elif cited > 20: score += 10
    elif cited > 5: score += 7
    elif cited > 0: score += 3

    # ===== 3. 年份 (最高 10 分) =====
    try:
        y = int(year)
        if y >= 2025: score += 10
        elif y >= 2023: score += 7
        elif y >= 2020: score += 5
        elif y >= 2015: score += 3
    except: pass

    p['score'] = score

unique.sort(key=lambda x: x.get('score',0), reverse=True)
total = len(unique)
high = [p for p in unique if p.get('score',0) >= 32]
mid = [p for p in unique if 25 <= p.get('score',0) < 32]

print()
print('=' * 60)
from datetime import datetime
now = datetime.now().strftime('%Y-%m-%d %H:%M')
print(f'  文献检索报告 (v6.0 - Agent 0 本地优先 + 全文验证)')
print(f'  时间: {now}')
print(f'  总计: {total} 篇 (去重后)')
print('=' * 60)
print()

# 来源统计
source_counts = {}
for p in unique:
    s = p.get('source', 'unknown')
    source_counts[s] = source_counts.get(s, 0) + 1
print('📊 来源分布:')
for s, c in sorted(source_counts.items(), key=lambda x: x[1], reverse=True):
    icon = '💾' if s == 'Local' else ('📘' if s == 'Guideline' else '📡')
    print(f'  {icon} {s}: {c} 篇')
print()

# 本地验证统计
local_verified = sum(1 for p in unique if p.get('is_local_verified'))
print(f'  💾 本地已验证: {local_verified} 篇 (Obsidian 知识库中已有全文/阅读报告)')
print()

# 显示 top-100（优先 high，依次补足 mid、low）
display = high[:100]
mid_needed = max(0, 100 - len(display))
if mid_needed and mid:
    display += mid[:mid_needed]
low_needed = max(0, 100 - len(display))
low = [p for p in unique if p.get('score',0) < 20]
if low_needed and low:
    display += low[:low_needed]

if display:
    print(f'## 📚 检索结果 (Top {len(display)})')
    print()
    for i, p in enumerate(display):
        t = p.get('title','')[:100]; s = p.get('score',0); pm = p.get('pmid','')
        src = p.get('source','')
        tier_label = '🔴' if s >= 32 else ('🟡' if s >= 25 else '⚪')
        local_tag = ' ✅本地已验证' if p.get('is_local_verified') else ''
        guideline_tag = ' 📘指南' if p.get('is_guideline') else ''
        source_tag = '💾本地' if src == 'Local' else ('📘指南' if src == 'Guideline' else f'📡{src}')
        print(f'**{tier_label} #{i+1}** [{s}分] {t} (PMID: {pm}) [{source_tag}]{local_tag}{guideline_tag}')
        abstract = p.get('abstract','').strip()
        if abstract:
            print(f'  > {abstract[:200]}')
        print()
    print(f'**说明**: 🔴高≥32 | 🟡中25-31 | ⚪一般<25 | 评分=期刊(0-25)+引用(0-20)+年份(0-10)+本地验证(0-5)')
    print()

# 提取 Top 100 高被引 PMID
all_pmids_in_order = [p.get('pmid','') for p in display if p.get('pmid','').strip()]
pmid_list = ','.join(all_pmids_in_order[:100])

# 注入强制指令
print('---')
print('## 🔴🔴🔴 强制执行：全文/摘要验证 🔴🔴🔴')
print()
print('你必须在报告中引用以下 PMID 的详细信息。')
print('请立即调用 mcp__pubmed__pubmed_fetch_articles(PMID) 或 pubmed_fetch_fulltext 读取以下内容！')
print()
if pmid_list:
    print('```')
    print(pmid_list)
    print('```')
print()
print('报告必须包含：剂量、样本量、方法学、不良反应，禁止仅凭标题写报告。')
PYEOF
}

# ===== 领域专家检索（专家→学会→指南→核心文献）=====
search_guideline_consensus() {
    local topic="$1"
    local tmpdir="$2"
    local en_kw_input="$3"
    log "  🔬 领域专家检索（指南/共识/学会）..."

    (
        # 整个 API 调用放在 Python 里执行，避免 shell 引号冲突
        python3 - "$en_kw_input" << 'PYEOF'
import sys, json, urllib.request, urllib.parse, re, time

en_kw = sys.argv[1] if len(sys.argv) > 1 else ""

# ===== 1. PubMed 指南/共识检索 =====
if en_kw:
    gw_term = f'{en_kw} AND ("Guideline"[Publication Type] OR "Consensus"[Publication Type] OR "Practice Guideline"[Publication Type] OR guideline[Title] OR consensus[Title])'
else:
    gw_term = 'guideline[Title] OR consensus[Title]'

enc_gw = urllib.parse.quote_plus(gw_term)
url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term={enc_gw}&retmax=30&retmode=json"

try:
    req = urllib.request.Request(url, headers={"User-Agent": "A2A-Dispatcher/2.0"})
    resp = urllib.request.urlopen(req, timeout=30)
    data = json.loads(resp.read())
    pmids = data.get("esearchresult", {}).get("idlist", [])[:30]

    if pmids:
        # 获取元数据
        pmid_str = ",".join(pmids)
        url2 = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id={pmid_str}&retmode=json"
        req2 = urllib.request.Request(url2, headers={"User-Agent": "A2A-Dispatcher/2.0"})
        resp2 = urllib.request.urlopen(req2, timeout=30)
        data2 = json.loads(resp2.read())
        results = data2.get("result", {})
        for pmid in results.pop("uids", []):
            item = results.get(pmid, {})
            title = item.get("title", "")[:120].replace("\n", " ")
            pubdate = item.get("pubdate", "")[:4]
            source = item.get("source", "")
            if title:
                print(f"[Guideline] PMID={pmid} Title={title} Year={pubdate} Journal={source} Cited=0")
    else:
        print("[INFO] PubMed 未找到指南/共识文献")
except Exception as e:
    print(f"[ERROR] PubMed 指南检索失败: {e}")

time.sleep(1)  # NCBI 速率限制保护（3 req/s 无 API Key）

# ===== 2. Europe PMC 指南补充 =====
if en_kw:
    gw_euro = urllib.parse.quote_plus(f"{en_kw} guideline OR consensus")
    url3 = f"https://www.ebi.ac.uk/europepmc/webservices/rest/search?query={gw_euro}&resultType=core&maxResults=20"
    try:
        req = urllib.request.Request(url3, headers={"User-Agent": "A2A-Dispatcher/2.0"})
        resp = urllib.request.urlopen(req, timeout=30)
        data = json.loads(resp.read())
        results = data.get("resultList", {}).get("result", [])
        for r in results[:20]:
            pmid = str(r.get("pmid", ""))
            if pmid and pmid != "0":
                title = r.get("title", "").replace("\n", " ")[:120]
                yr = r.get("pubYear", "")
                jn = r.get("journalTitle", "")
                cited = r.get("citedByCount", 0)
                print(f"[Guideline] PMID={pmid} Title={title} Year={yr} Journal={jn} Cited={cited}")
    except:
        pass

# ===== 3. OpenAlex 高被引经典文献（被引>100 = 指南级）=====
if en_kw:
    enc_oa = urllib.parse.quote_plus(en_kw)
    url4 = f"https://api.openalex.org/works?search={enc_oa}&per_page=50"
    try:
        req = urllib.request.Request(url4, headers={"User-Agent": "A2A-Dispatcher/2.0"})
        resp = urllib.request.urlopen(req, timeout=30)
        data = json.loads(resp.read())
        for r in data.get("results", [])[:50]:
            cited = r.get("cited_by_count", 0)
            if cited < 100:
                continue
            ids = r.get("ids", {})
            pmid_raw = ids.get("pmid", "")
            m = re.search(r"/(\d+)", pmid_raw) if pmid_raw else None
            pmid = m.group(1) if m else ""
            title = r.get("title", "").replace("\n", " ")[:120]
            yr = r.get("publication_year", "")
            pl = r.get("primary_location") or {}
            src = pl.get("source") or {}
            jn = src.get("display_name", "")
            pmid_str = f" PMID={pmid}" if pmid else ""
            print(f"[Guideline] Title={title}{pmid_str} Year={yr} Cited={cited} Journal={jn}")
    except:
        pass
PYEOF
    ) > "$tmpdir/guideline.txt" &
}

dispatch_literature_search() {
    local topic="$1"
    log "📚 文献检索任务 (v6.0 - Agent 0 本地优先 + 全文验证): $topic"
    local enc_topic=$(python3 -c "import sys; from urllib.parse import quote_plus; print(quote_plus(sys.argv[1]))" "$topic" 2>/dev/null)
    local tmpdir=$(mktemp -d /tmp/a2a_search_XXXXXX)

    # ===== Agent 0: 本地 Obsidian 知识库（阻塞，最先执行）=====
    search_local_obsidian "$topic" "$tmpdir"
    ok "Agent 0 完成"

    log "⏳ 开始7路并行检索（PubMed+OpenAlex+CrossRef+EuropePMC+SemScholar+PMC+Guideline）..."
    # OpenAlex uses English keywords only (title.search is English tokenizer)
    # Extract English keywords from topic, fallback to common medical terms
    local en_kw=$(echo "$topic" | grep -oE '[a-zA-Z]{4,}' | head -3 | tr '\n' ' ' | sed 's/ $//')
    local openalex_kw=""
    if [ -n "$en_kw" ]; then
        openalex_kw="$en_kw"
    else
        openalex_kw=$(python3 -c "
topic = '''$topic'''
cn2en = {
    '艾司氯胺酮': 'esketamine', '氯胺酮': 'ketamine',
    '解离': 'dissociation', '抑郁': 'depression',
    '镇静': 'sedation', '焦虑': 'anxiety',
    '躁动': 'agitation', '谵妄': 'delirium',
    '失眠': 'insomnia', '精神分裂': 'schizophrenia',
    '双相': 'bipolar', '麻醉': 'anesthesia',
    '镇痛': 'analgesia', '右美托咪定': 'dexmedetomidine',
    '丙泊酚': 'propofol', '咪达唑仑': 'midazolam',
    '瑞马唑仑': 'remimazolam', '阿片': 'opioid', '纳布啡': 'nalbuphine',
}
kws = [en for cn, en in cn2en.items() if cn in topic]
print(' '.join(kws) if kws else 'psychiatry')
" 2>/dev/null)
    fi
    # 确保 en_kw 也有正确的英文关键词（PubMed/PMC/Guideline 共用）
    en_kw="$openalex_kw"
    log "  OpenAlex 关键词: $openalex_kw"
    search_api 'OpenAlex' "https://api.openalex.org/works?search=$(python3 -c "import urllib.parse; print(urllib.parse.quote_plus('$openalex_kw'))" 2>/dev/null)&per_page=50" '
import json, sys, re
data = json.load(sys.stdin)
for r in data.get("results", [])[:50]:
    title = r.get("title","").replace("\n"," ")
    doi = r.get("doi","")
    year = r.get("publication_year","")
    cited = r.get("cited_by_count",0)
    journal = ""
    ids = r.get("ids", {})
    pmid_raw = ids.get("pmid","")
    # OpenAlex 返回 PMID URL，提取纯数字
    m = re.search(r"/(\d+)", pmid_raw) if pmid_raw else None
    pmid = m.group(1) if m else pmid_raw
    pl = r.get("primary_location") or {}
    src = pl.get("source") or {}
    journal = src.get("display_name","")
    pmid_str = f" PMID={pmid}" if pmid else ""
    print(f"[OpenAlex] Title={title} DOI={doi}{pmid_str} Year={year} Cited={cited} Journal={journal}")
' "$tmpdir/openalex.txt"

    search_api "CrossRef" "https://api.crossref.org/works?query=$enc_topic&rows=50&select=title,abstract,DOI,published-print,container-title,is-referenced-by-count" '
import json, sys
data = json.load(sys.stdin)
for r in data.get("message",{}).get("items",[])[:50]:
    pd = (r.get("published-print",{}) or {}).get("date-parts",[[[""]]])[0][0] if r.get("published-print",{}) else ""
    ct = " ".join(r.get("container-title",[])) if r.get("container-title") else ""
    title = " ".join(r.get("title",[""]))
    doi = r.get("DOI","")
    cited = r.get("is-referenced-by-count",0)
    abstract = r.get("abstract","")[:300].replace("\n"," ")
    print(f"[CrossRef] Title={title} DOI={doi} Year={pd} Cited={cited} Journal={ct} Abstract={abstract}")
' "$tmpdir/crossref.txt"

    search_api "EuropePMC" "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=$enc_topic&format=json&maxResults=50" '
import json, sys
data = json.load(sys.stdin)
results = data.get("resultList",{}).get("result",[])
for r in results[:50]:
    pmid = str(r.get("pmid",""))
    title = r.get("title","").replace("\n"," ")
    yr = r.get("pubYear","")
    cited = r.get("citedByCount",0)
    jname = r.get("journalTitle","")
    abstract = r.get("abstractText","")[:300].replace("\n"," ")
    print(f"[EuropePMC] Title={title} PMID={pmid} Year={yr} Cited={cited} Journal={jname} Abstract={abstract}")
' "$tmpdir/europepmc.txt"

    # === PMC 全文检索（免费全文核心库） ===
    log "  📚 PMC 全文检索中..."
    sleep 1  # NCBI 速率限制保护
    (
        local pmc_topic=$(python3 -c "import urllib.parse; print(urllib.parse.quote_plus('$en_kw'))" 2>/dev/null)
        local pmc_ids=$(curl -s --max-time 30 -H "User-Agent: A2A-Dispatcher/2.0" "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pmc&term=${pmc_topic}&retmax=50&retmode=json" \
            | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("esearchresult",{}).get("idlist",[])[:50]))' 2>/dev/null)
        if [ -n "$pmc_ids" ]; then
            for pmcid in $(echo "$pmc_ids" | tr ',' '\n' | head -20); do
                curl -s --max-time 15 -H "User-Agent: A2A-Dispatcher/2.0" \
                    "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pmc&id=${pmcid}&retmode=json" \
                | python3 -c "
import json, sys
data = json.load(sys.stdin)
for uid in data.get('result',{}).get('uids',[]):
    item = data.get('result',{}).get(uid,{})
    title = item.get('title','').replace('\n',' ')[:120]
    doi = item.get('doi','')
    pubdate = item.get('pubdate','')[:10]
    source = item.get('source','')
    abstract = ''
    for s in item.get('summaries',[]):
        abstract = str(s).replace('\n',' ')[:300]
        break
    print(f'[PMC-全文] Title={title} PMCID={uid} DOI={doi} Year={pubdate[:4]} Journal={source} Abstract={abstract}')
" 2>/dev/null
            done
        else
            echo "[INFO] PMC 全文检索返回 0 篇"
        fi
    ) > "$tmpdir/pmc_fulltext.txt" &

    search_api "SemanticScholar" "https://api.semanticscholar.org/graph/v1/paper/search?query=$enc_topic&limit=50&fields=title,abstract,year,citationCount,externalIds,journal" '
import json, sys
data = json.load(sys.stdin)
for r in data.get("data",[])[:50]:
    ext = r.get("externalIds",{}) or {}
    jnl = r.get("journal",{}) or {}
    title = r.get("title","").replace("\n"," ")
    jname = jnl.get("name","")
    pmid = ext.get("PubMed","")
    yr = r.get("year","")
    cited = r.get("citationCount",0)
    abstract = r.get("abstract","")[:300].replace("\n"," ")
    print(f"[SemanticScholar] Title={title} PMID={pmid} Year={yr} Cited={cited} Journal={jname} Abstract={abstract}")
' "$tmpdir/semanticscholar.txt"

    log "  🔴 PubMed: 临床文献核心库..."
    sleep 1  # NCBI 速率限制保护（避免与 OpenAlex/CrossRef 等并行竞争）
    (
        # 使用英文关键词搜索 PubMed（中文 URL 编码 PubMed 无法正确解析）
        local search_term="$enc_topic"
        if [ -n "$en_kw" ]; then
            search_term=$(python3 -c "
import sys
from urllib.parse import quote_plus
print(quote_plus(sys.argv[1]))
" "$en_kw" 2>/dev/null)
        fi
        pmids=$(curl -s --max-time 30 -H "User-Agent: A2A-Dispatcher/2.0" "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${search_term}&retmax=50&retmode=json" \
            | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("esearchresult",{}).get("idlist",[])[:50]))' 2>/dev/null)
        if [ -n "$pmids" ]; then
            curl -s --max-time 30 -H "User-Agent: A2A-Dispatcher/2.0" \
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=$pmids&retmode=json" \
            | python3 -c '
import json, sys
data = json.load(sys.stdin)
results = data.get("result", {})
uid_list = results.pop("uids", [])
for pmid in uid_list:
    item = results.get(pmid, {})
    title = item.get("title", "")[:120]
    pubdate = item.get("pubdate", "")[:4]
    source = item.get("source", "")
    if title:
        print(f"[PubMed] PMID={pmid} Title={title} Year={pubdate} Journal={source} Cited=0")
' 2>/dev/null
        else
            echo "[ERROR] PubMed esearch 返回 0 篇" > "$tmpdir/pubmed.txt"
        fi
    ) > "$tmpdir/pubmed.txt" &

    # 等待所有后台 API 调用完成（最多 90 秒）
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        local bg_count
        bg_count=$(jobs 2>/dev/null | wc -l | tr -d ' ')
        [ "$bg_count" -eq 0 ] && break
        sleep 3
        elapsed=$((elapsed+3))
    done
    # 额外等待，确保文件写入完成
    sleep 2

    # === Unpaywall 免费全文链接（等所有 API 完成后查 DOIs 的 OA 状态） ===
    log "  🔓 Unpaywall OA 链接检索中..."
    (
        # 从已完成的 API 输出中提取 DOIs
        local dois=$(grep -ohE '10\.[0-9]{4,9}/[a-zA-Z0-9._-]+' "$tmpdir"/*.txt 2>/dev/null | sort -u | head -20)
        if [ -n "$dois" ]; then
            echo "$dois" | while read -r doi; do
                [ -z "$doi" ] && continue
                curl -s --max-time 10 -H "User-Agent: A2A-Dispatcher/2.0" \
                    "https://api.unpaywall.org/v2/works/${doi}?email=research@a2a" \
                | python3 -c "
import json, sys
data = json.load(sys.stdin)
doi = data.get('doi','')
is_oa = data.get('is_oa', False)
best = data.get('best_oa_location') or {}
oa_url = best.get('url','')
oa_type = best.get('license','') or ''
print(f'[Unpaywall] DOI={doi} OA={is_oa} URL={oa_url} Type={oa_type}')
" 2>/dev/null
            done
        else
            echo "[INFO] Unpaywall: 未找到可查询的 DOI"
        fi
    ) > "$tmpdir/unpaywall.txt" 2>/dev/null

    # === 领域专家检索：指南/共识/高被引经典文献（串行，避免与 PubMed 主检索竞争 NCBI 速率限制） ===
    search_guideline_consensus "$topic" "$tmpdir" "$en_kw"
    sleep 2

    # 统计 API 响应情况
    local api_files="pubmed.txt openalex.txt crossref.txt semanticscholar.txt europepmc.txt pmc_fulltext.txt guideline.txt unpaywall.txt"
    local api_success=0 api_error=0 api_empty=0
    for f in $api_files; do
        if [ -s "$tmpdir/$f" ]; then
            if grep -q '^\[ERROR\]' "$tmpdir/$f" 2>/dev/null; then
                api_error=$((api_error+1))
            else
                api_success=$((api_success+1))
            fi
        else
            api_empty=$((api_empty+1))
        fi
    done
    log "  API 响应: ✅${api_success}/8  ❌${api_error}/8  ⬜${api_empty}/8 (空文件)"

    local total=0
    for f in "$tmpdir"/*.txt; do
        [ -s "$f" ] && total=$((total + $(wc -l < "$f")))
    done
    ok "10路检索完成 (1本地+7并行API+1串行Unpaywall+1指南): $total 篇原始结果"

    log "⏳ 去重 + 评分（Agent 0 本地优先 + 期刊优先）..."
    deduplicate_and_score "$tmpdir"
    log "⏳ 军事医学图书馆全文验证..."
    check_full_text "$tmpdir"

    # 保留 tmpdir 供验证脚本使用（verify-delivery.sh 需要读取目录）
    log "📁 输出目录: $tmpdir"
    log "✅ 检索完成"
}

check_full_text() {
    local tmpdir="$1"
    local pmid_file="$tmpdir/all_raw.txt"
    [ -f "$tmpdir/obsidian_pmids.txt" ] && local obsidian_pmids=$(cat "$tmpdir/obsidian_pmids.txt")

    python3 - "$pmid_file" "$obsidian_pmids" "$tmpdir" << 'PYEOF'
import sys, re, os, json
from urllib.request import urlopen, Request
from concurrent.futures import ThreadPoolExecutor, as_completed

all_raw = sys.argv[1]
obsidian_pmids_str = sys.argv[2] if len(sys.argv) > 2 else ""
obsidian_pmids = set(obsidian_pmids_str.split(',')) if obsidian_pmids_str else set()
tmpdir = sys.argv[3]

# ===== 1. 提取 Top 20 PMID =====
pmids = []
seen = set()
for line in open(all_raw, encoding='utf-8'):
    line = line.strip()
    if not line or not line.startswith('['): continue
    m = re.match(r'\[(\w+)\]\s+.*?PMID=(\d+)', line)
    if m:
        pmid = m.group(2)
        if pmid not in seen:
            seen.add(pmid)
            pmids.append(pmid)

pmids = pmids[:20]  # 只检查前 20 个有 PMID 的

if not pmids:
    print()
    print('  ⚪ 没有 PMID 需要全文验证')
    exit(0)

# ===== 2. 批量检查欧洲PMC =====
def check_europepmc_batch(pmids):
    """批量检查 EuropePMC - 一次请求查所有"""
    results = {}
    try:
        query = '+'.join([f'EXT_ID:{p}' for p in pmids])
        url = f"https://www.ebi.ac.uk/europepmc/webservices/rest/search?query={query}&format=json&maxResults=50"
        req = Request(url, headers={'User-Agent': 'A2A-Dispatcher/2.0'})
        resp = urlopen(req, timeout=10)
        data = json.loads(resp.read().decode())
        for r in data.get('result',{}).get('resultList',{}).get('result',[]):
            pmid = str(r.get('pmid',''))
            is_open = r.get('isOpenAccess') == 'Y'
            has_fulltext = bool(r.get('fullTextUrlList'))
            results[pmid] = {'open': is_open, 'fulltext': has_fulltext, 'source': 'EuropePMC'}
    except Exception as e:
        print(f'  EuropePMC 批量检查失败: {e}', file=sys.stderr)
    return results

# ===== 3. 检查 PMC（并发）=====
def check_pmc(pmid):
    """检查 PMC 开放获取"""
    try:
        url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pmc&id={pmid}&rettype=xml&retmode=text"
        req = Request(url, headers={'User-Agent': 'A2A-Dispatcher/2.0'})
        resp = urlopen(req, timeout=3)
        if resp.getcode() == 200:
            return pmid, True, 'PMC'
    except:
        pass
    return pmid, False, None

# ===== 4. 执行检查 =====
print()
print('=' * 60)
print(f'  🔍 全文获取验证 (Top {len(pmids)} PMID)')
print('=' * 60)
print()

# 批量检查 EuropePMC
europepmc_results = check_europepmc_batch(pmids)

# 并发检查 PMC（只检查 EuropePMC 没找到的）
pmc_results = {}
needs_pmc_check = [p for p in pmids if p not in europepmc_results]
if needs_pmc_check:
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {executor.submit(check_pmc, p): p for p in needs_pmc_check}
        for future in as_completed(futures, timeout=30):
            try:
                pmid, found, src = future.result()
                if found:
                    pmc_results[pmid] = {'open': True, 'source': 'PMC'}
            except:
                pass

# ===== 5. 合并结果 =====
free_count = 0
sub_count = 0
results = []
free_pmids = []

for pmid in pmids:
    status = 'unknown'
    source = 'unknown'

    # 1. 检查 EuropePMC 批量结果
    if pmid in europepmc_results:
        ep = europepmc_results[pmid]
        if ep['open'] or ep['fulltext']:
            status = 'free'
            source = 'EuropePMC'

    # 2. 检查 PMC
    if status == 'unknown' and pmid in pmc_results:
        status = 'free'
        source = 'PMC'

    # 3. 检查本地
    if status == 'unknown' and pmid in obsidian_pmids:
        status = 'free'
        source = 'Local'

    if status == 'free':
        free_count += 1
        free_pmids.append(pmid)
        marker = '🆓'
        label = f'✅ 免费 ({source})'
    else:
        sub_count += 1
        marker = '🏥'
        label = '🏥 机构订阅'

    results.append(f'{marker} PMID:{pmid} → {label}')

# ===== 6. 输出统计 =====
total = len(pmids)
free_pct = free_count/total*100 if total > 0 else 0
sub_pct = sub_count/total*100 if total > 0 else 0

print(f'📊 全文获取统计:')
print(f'  🆓 免费获取: {free_count}/{total} 篇 ({free_pct:.0f}%)')
print(f'  🏥 机构订阅: {sub_count}/{total} 篇 ({sub_pct:.0f}%)')
print()

print(f'## 📚 全文获取详情')
print()
for r in results:
    print(f'  {r}')
print()

print('---')
print('## 🆓 免费获取优先（强制顺序）')
print()
print('1. **PMC 开放获取** — 直接下载 PDF')
print('2. **Europe PMC** — 补充免费文献')
print('3. **军事医学图书馆** — 机构订阅（已标记 🏥）')
print('4. **本地 Obsidian** — 已有全文/阅读报告（已标记 ✅本地已验证）')
print()
print('🏥 标记的文献需要通过军事医学图书馆获取全文：')
print('```')
print('https://yc.mlpla.mil.cn')
print('```')
print()

# ===== 7. 输出免费 PMID 列表 =====
free_pmid_file = os.path.join(tmpdir, 'free_pmids.txt')
with open(free_pmid_file, 'w') as f:
    f.write(','.join(free_pmids))

print(f'  ✅ 免费获取列表: {len(free_pmids)} 个 PMID 已保存')
PYEOF
}

dispatch_article_publish() {
    local topic="$1" mode="${2:-draft}"
    log "📝 公众号发布: $topic (模式: $mode)"
}

case "${1:-help}" in
    search)
        dispatch_literature_search "${2:-}"
        # 自动运行透明度验证
        if [ -x "$A2A_HOME/bin/verify-delivery.sh" ]; then
            log "🔍 运行透明度验证..."
            "$A2A_HOME/bin/verify-delivery.sh" "${2:-}" "" 1 2>&1 | while read -r line; do
                log "  $line"
            done
        fi
        ;;
    publish) dispatch_article_publish "${2:-}" "${3:-draft}" ;;
    *) echo "用法: a2a-dispatcher search \"关键词\"" ;;
esac

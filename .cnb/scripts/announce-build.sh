#!/bin/sh
# ===================================================================
# 构建记录 Issue（CNB 专用）：每个变体一条 Issue，构建完成后更新正文，
# 版本号变化时追加一条评论。
#
# 为什么每个变体一条、而不是每天一条：十个变体就是十条常驻 Issue，历史都留在
# 评论里，Issue 列表不会每天多出十条；版本没变的日子也不发「无变化」评论。
#
# 上一次版本记在评论开头的单行标记里（评论发出后删不掉，重跑也能读回来）：
#   <!-- build-announce-state:golang_version=1.25.4;wails3_version=v3.1.0 -->
# 标记放在开头：评论后面要附完整的 annotation JSON，万一 CLI 列表输出截断长
# 字符串，开头的标记仍然读得到。
# 不落盘、不提交：构建仓库里没有可长期保存状态的地方，Issue 本身就是状态库。
# 每次读最近一条带标记的评论做 diff（list 按创建时间倒序，取第一条即可）。
#
# 用法（各 build-*.yml 的最后一个 stage 调用）：
#   sh .cnb/scripts/announce-build.sh <变体>
#
# 依赖：cnbcool/cnb-cli 镜像里的 cnb 命令、CNB 注入的 CNB_TOKEN / CNB_REPO_SLUG，
#       以及构建阶段写出的 .cnb/annotation[-<变体>].json（stage 共享工作区）。
#
# 失败只告警不退出：公告是附加动作，不能把已经成功的镜像构建标红。
# ===================================================================

set -eu

info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
skip() {
  warn "$*"
  exit 0
}

variant="${1:-}"
case "$variant" in
  golang | fnpack | wails3 | wails2 | fyne | mygo | gio | nsgo | viva | asuka) : ;;
  *) skip "用法: sh .cnb/scripts/announce-build.sh <golang|fnpack|wails3|wails2|fyne|mygo|gio|nsgo|viva|asuka>" ;;
esac

REPO="${CNB_REPO_SLUG:-${CNB_REPO_SLUG_LOWERCASE:-}}"
[ -n "$REPO" ] || skip "缺少 CNB_REPO_SLUG / CNB_REPO_SLUG_LOWERCASE，跳过构建公告"

if [ "$variant" = "golang" ]; then
  ANNOTATION_FILE=".cnb/annotation.json"
else
  ANNOTATION_FILE=".cnb/annotation-${variant}.json"
fi
[ -f "$ANNOTATION_FILE" ] || skip "找不到 ${ANNOTATION_FILE}（构建元数据未生成），跳过构建公告"

# 从 annotation 里取一个字符串字段。annotation 由构建脚本按「一行一个 key」写出，
# 值都是版本号 / 镜像名 / digest 这类不含转义引号的普通字符串，sed 足够。
json_string() {
  sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\(.*\)\"[,]*[[:space:]]*$/\1/p" \
    "$ANNOTATION_FILE" | head -n 1
}

# annotation 里的 built_at 是 UTC（OCI 元数据惯例，JSON 里保持原样），
# 评论 / 正文里面向人看的文字换成北京时间。
# 解析用 BSD 的 date -j -f 与 GNU / busybox 的 date -d 双兼容，不依赖 tzdata。
display_time() {
  iso="$1"
  [ -n "${iso}" ] || iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # busybox 的 date -d 不一定认识 ISO 的 T / Z，备一份空格分隔的写法。
  iso_plain="$(printf '%s' "${iso}" | sed 's/T/ /; s/Z$//')"
  epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso}" +%s 2>/dev/null \
    || date -u -d "${iso_plain}" +%s 2>/dev/null || true)"
  if [ -z "${epoch}" ]; then
    printf '%s' "${iso}"
    return 0
  fi
  date -u -r $((epoch + 28800)) '+%Y-%m-%d %H:%M:%S +08:00' 2>/dev/null \
    || date -u -d "@$((epoch + 28800))" '+%Y-%m-%d %H:%M:%S +08:00' 2>/dev/null \
    || printf '%s' "${iso}"
}

tmp="$(mktemp -d 2>/dev/null || true)"
if [ -z "${tmp}" ]; then
  tmp="/tmp/build-announce-${variant}"
  mkdir -p "${tmp}"
fi
trap 'rm -rf "${tmp}"' EXIT

# ---------- 本次状态 ----------
# 参与 diff 的字段：Go 版本 + 变体自身的工具版本。image_version 就是 Go 版本
# （标签也用 Go 版本），不重复记录。golang 基座额外记录内置 CLI 的版本表。
case "$variant" in
  golang) VERSION_KEYS="golang_version tools" ;;
  mygo) VERSION_KEYS="golang_version mygo_version bun_version" ;;
  *) VERSION_KEYS="golang_version ${variant}_version" ;;
esac

label_for() {
  case "$1" in
    golang_version) printf 'Go' ;;
    tools) printf '内置工具' ;;
    *_version) printf '%s' "${1%_version}" ;;
    *) printf '%s' "$1" ;;
  esac
}

print_current_versions() {
  for key in $VERSION_KEYS; do
    value="$(json_string "${key}")"
    [ -n "${value}" ] || continue
    printf '%s\n' "- $(label_for "${key}")：\`${value}\`"
  done
}

# 附上本次构建的完整元数据，方便对照层版本 / 系统包 / digest 排查。
print_annotation() {
  printf '\n<details>\n<summary>构建元数据（%s）</summary>\n\n```json\n' "${ANNOTATION_FILE}"
  # awk 保证文件末尾有且只有一个换行，代码块不会和收尾的 ``` 粘在一起。
  awk '1' "${ANNOTATION_FILE}"
  printf '```\n\n</details>\n'
}

# 计算 base 状态与当前 annotation 的差异；结果放在 DIFF_LINES / DIFF_COUNT。
diff_state() {
  DIFF_LINES=""
  DIFF_COUNT=0
  for key in $VERSION_KEYS; do
    new_value="$(json_string "${key}")"
    [ -n "${new_value}" ] || continue
    old_value="$(printf '%s' "$1" | tr ';' '\n' \
      | sed -n "s/^${key}=//p" | head -n 1)"
    if [ "${old_value}" = "${new_value}" ]; then
      continue
    fi
    DIFF_COUNT=$((DIFF_COUNT + 1))
    if [ "${key}" = "tools" ]; then
      line="- 内置工具：版本有变化"
    elif [ -z "${old_value}" ]; then
      line="- $(label_for "${key}")：\`${new_value}\`"
    else
      line="- $(label_for "${key}")：\`${old_value}\` → \`${new_value}\`"
    fi
    DIFF_LINES="${DIFF_LINES}${line}
"
  done
}

STATE=""
for key in $VERSION_KEYS; do
  value="$(json_string "${key}")"
  [ -n "${value}" ] || continue
  if [ -n "${STATE}" ]; then
    STATE="${STATE};${key}=${value}"
  else
    STATE="${key}=${value}"
  fi
done
[ -n "${STATE}" ] || skip "${ANNOTATION_FILE} 里没有可公告的版本字段，跳过构建公告"

IMAGE_REF="$(json_string "${variant}_image")"
DIGEST="$(json_string "${variant}_digest")"
DIGEST_SHORT="$(json_string "${variant}_digest_short")"
SIZE_AMD64="$(json_string "${variant}_size")"
SIZE_ARM64="$(json_string "${variant}_size_arm64")"
BUILT_AT="$(json_string built_at)"
[ -n "${BUILT_AT}" ] || BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILT_AT_DISPLAY="$(display_time "${BUILT_AT}")"
COMMIT_SHORT="$(printf '%s' "${CNB_COMMIT:-unknown}" | cut -c1-8)"

# ---------- 正文：当前版本（每次构建都刷新） ----------
BODY_FILE="${tmp}/body.md"
{
  printf '本 Issue 由 CNB 构建流水线自动维护：每次构建更新「当前版本」，版本号变化时追加评论。\n\n'
  printf '| 项目 | 当前值 |\n| --- | --- |\n'
  printf '| 镜像 | `%s` |\n' "${IMAGE_REF:-unknown}"
  for key in $VERSION_KEYS; do
    value="$(json_string "${key}")"
    printf '| %s | `%s` |\n' "$(label_for "${key}")" "${value:-unknown}"
  done
  printf '| 摘要 | `%s` |\n' "${DIGEST_SHORT:-${DIGEST:-unknown}}"
  printf '| 体积 | amd64 %s / arm64 %s |\n' "${SIZE_AMD64:-unknown}" "${SIZE_ARM64:-unknown}"
  printf '\n最近构建：%s · 提交 `%s`\n' "${BUILT_AT_DISPLAY}" "${COMMIT_SHORT}"
} >"${BODY_FILE}"

# ---------- 找 Issue：每个变体一条，标题固定 ----------
TITLE="[镜像] ${variant} 构建记录"
LABEL="构建记录"

# cnb CLI 的输出是 util.inspect 风格（对象属性逐行），按「上一个 number 行 +
# 当前 title 行」配对；number 与 title 都可能带引号，先剥掉再比较，避免
# v1.2.3 误匹配 v1.2.30。
find_number_in() {
  # cnb CLI 的字符串可能被单引号或双引号包着；q 用 sprintf 生成单引号，
  # 避免在 shell 单引号里再写单引号。
  awk -v t="${TITLE}" '
    BEGIN { q = sprintf("%c", 39) }
    /^[[:space:]]*(-[[:space:]]+)?number: / {
      v = $NF; gsub(/[^0-9]/, "", v); if (v != "") n = v
    }
    /^[[:space:]]*(-[[:space:]]+)?title: / {
      line = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?title: /, "", line)
      gsub("^[" q "\",]+|[" q "\",]+$", "", line)
      if (line == t && n != "") { print n; exit }
    }
  ' "$1"
}

NUMBER=""
FOUND_STATE=""
for issue_state in open closed; do
  list_file="${tmp}/issues-${issue_state}.txt"
  cnb issues list-issues \
    --repo "${REPO}" \
    --state "${issue_state}" \
    --keyword "${variant}" \
    --page 1 \
    --page-size 50 \
    >"${list_file}" 2>&1 || true
  NUMBER="$(find_number_in "${list_file}" || true)"
  if [ -n "${NUMBER}" ]; then
    FOUND_STATE="${issue_state}"
    break
  fi
done

IS_NEW=no
if [ -n "${NUMBER}" ]; then
  info "找到 Issue #${NUMBER}（${FOUND_STATE}）：${TITLE}"
  if [ "${FOUND_STATE}" = "closed" ]; then
    cnb issues update-issue --repo "${REPO}" --number "${NUMBER}" --state open \
      >"${tmp}/reopen.txt" 2>&1 \
      || warn "重新打开 #${NUMBER} 失败（继续在其上评论）：$(head -n 3 "${tmp}/reopen.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if cnb issues update-issue --repo "${REPO}" --number "${NUMBER}" --body-file "${BODY_FILE}" \
    >"${tmp}/update.txt" 2>&1; then
    info "已更新正文里的当前版本"
  else
    warn "更新正文失败（不影响评论）：$(head -n 5 "${tmp}/update.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
else
  IS_NEW=yes
  # 仓库里没有「构建记录」标签时，带标签建 Issue 会被拒；先建标签，已存在时
  # 接口报 400、忽略即可。带标签仍失败时去掉标签再试一次。
  cnb repo-labels post-label \
    --repo "${REPO}" \
    --name "${LABEL}" \
    --color "52c41a" \
    --description "镜像构建记录（流水线自动维护）" \
    >/dev/null 2>&1 || true
  if ! cnb issues create-issue \
    --repo "${REPO}" \
    --title "${TITLE}" \
    --body-file "${BODY_FILE}" \
    --labels "${LABEL}" \
    >"${tmp}/create.txt" 2>&1; then
    cnb issues create-issue \
      --repo "${REPO}" \
      --title "${TITLE}" \
      --body-file "${BODY_FILE}" \
      >"${tmp}/create.txt" 2>&1 || true
  fi
  NUMBER="$(grep -oE 'number: .?[0-9]+' "${tmp}/create.txt" 2>/dev/null \
    | head -n 1 | grep -oE '[0-9]+' || true)"
  [ -n "${NUMBER}" ] || skip "创建 Issue 失败或没解析到编号：$(head -n 5 "${tmp}/create.txt" 2>/dev/null | tr '\n' ' ' || true)"
  info "已创建 Issue #${NUMBER}：${TITLE}"
fi

# ---------- 读上一次状态 ----------
PREV_STATE=""
HISTORY_OK=yes
if [ "${IS_NEW}" = no ]; then
  cnb issues list-issue-comments \
    --repo "${REPO}" \
    --number "${NUMBER}" \
    --sort -created \
    --page-size 50 \
    >"${tmp}/comments.txt" 2>&1 || true
  if grep -q 'status: 2' "${tmp}/comments.txt" 2>/dev/null; then
    # 列表按创建时间倒序，第一条带标记的评论就是上一次构建的状态。
    # 标记后紧跟正文，截到第一个「 -->」；去掉标记尾部空格（值里可能带空格，
    # 如 golang 的内置工具表），否则永远判为变化。
    PREV_STATE="$(sed -n 's/.*build-announce-state://p' "${tmp}/comments.txt" \
      | sed 's/ -->.*//' | sed 's/[[:space:]]*$//' | head -n 1)"
  else
    HISTORY_OK=no
    warn "读取历史评论失败，本次不评论（避免重复）"
  fi
fi

if [ "${HISTORY_OK}" = no ]; then
  exit 0
fi

# ---------- 常规评论：版本有变化时才发 ----------
diff_state "${PREV_STATE}"

if [ "${IS_NEW}" = no ] && [ "${DIFF_COUNT}" -eq 0 ]; then
  info "版本无变化（${STATE}），跳过常规评论"
else
  COMMENT_FILE="${tmp}/comment.md"
  {
    printf '<!-- build-announce-state:%s -->\n\n' "${STATE}"
    # 先 @ 仓库里的 NPC（见 .cnb/settings.yml 的 npc/CodeBuddy），让它根据下面的
    # 版本变化与 annotation 整理一版面向使用者的说明，作为评论发回来。
    printf '@CodeBuddy 请根据下面的版本变化和构建元数据，整理一份面向使用者的简洁更新说明（按新增 / 变更 / 修复分组，忽略内部实现细节），并作为评论发布在这里。\n\n'
    if [ "${IS_NEW}" = yes ] || [ -z "${PREV_STATE}" ]; then
      printf '## %s 首次构建记录（北京时间）\n\n当前版本：\n' "${BUILT_AT_DISPLAY}"
      print_current_versions
    else
      printf '## %s 版本变化（北京时间）\n\n%s' "${BUILT_AT_DISPLAY}" "${DIFF_LINES}"
    fi
    printf '\n'
    printf '%s\n' "- 镜像：\`${IMAGE_REF:-unknown}\`"
    printf '%s\n' "- 摘要：\`${DIGEST_SHORT:-${DIGEST:-unknown}}\`"
    printf '%s\n' "- 提交：\`${COMMIT_SHORT}\`"
    print_annotation
  } >"${COMMENT_FILE}"

  if cnb issues post-issue-comment \
    --repo "${REPO}" \
    --number "${NUMBER}" \
    --body-file "${COMMENT_FILE}" \
    >"${tmp}/post.txt" 2>&1; then
    info "✓ 已发布评论到 Issue #${NUMBER}"
  else
    warn "发布评论失败：$(head -n 5 "${tmp}/post.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
fi

# ---------- 周 / 月总结 ----------
# 周一：总结上一个星期；每月 1 号：总结上一个月，都发在同一条变体 Issue 里。
# 基线来自上一次同名总结评论顶部的快照标记：
#   <!-- build-summary-state:weekly:2026-11-24:golang_version=...;... -->
# 两次总结之间的版本变化就是「上一个星期 / 上一个月」；首次没有基线时只记录
# 当前版本、建立基线。周一与 1 号重合时合并成一条，避免同一天发两遍。
if [ "${IS_NEW}" = yes ]; then
  exit 0
fi

# CNB 的 cron 按 Asia/Shanghai 解释，这里也按 UTC+8 算日期；不依赖镜像里有没有
# tzdata（date -u -r 是 BSD，date -u -d @... 是 GNU / busybox）。
NOW_EPOCH="$(date -u +%s)"
CN_CAL="$(date -u -r $((NOW_EPOCH + 28800)) '+%u %d %Y-%m-%d' 2>/dev/null \
  || date -u -d "@$((NOW_EPOCH + 28800))" '+%u %d %Y-%m-%d' 2>/dev/null || true)"
WEEKDAY="${CN_CAL%% *}"
CN_DAY="${CN_CAL#* }"
CN_DAY="${CN_DAY%% *}"
CN_DATE="${CN_CAL##* }"
case "${CN_DATE}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) skip "无法计算 Asia/Shanghai 日期，跳过周/月总结" ;;
esac

POST_WEEKLY=no
POST_MONTHLY=no
if [ "${WEEKDAY}" = "1" ]; then
  POST_WEEKLY=yes
fi
if [ "$(printf '%s' "${CN_DAY}" | sed 's/^0//')" = "1" ]; then
  POST_MONTHLY=yes
fi
if [ "${POST_WEEKLY}" = no ] && [ "${POST_MONTHLY}" = no ]; then
  exit 0
fi

# 读最近一条同类总结的日期与版本快照；今天已经发过就跳过（重跑幂等）。
# 同一天周/月总结合并成一条评论、两个标记，截到第一个「 -->」即可分别取出。
read_summary_marker() {
  marker="$(sed -n "s/.*build-summary-state:$1://p" "${tmp}/comments.txt" \
    | sed 's/ -->.*//' | sed 's/[[:space:]]*$//' | head -n 1)"
  MARK_DATE="${marker%%:*}"
  MARK_STATE="${marker#*:}"
}

WEEK_BASE_DATE=""
WEEK_BASE_STATE=""
if [ "${POST_WEEKLY}" = yes ]; then
  read_summary_marker weekly
  if [ "${MARK_DATE}" = "${CN_DATE}" ]; then
    info "今天已发过周总结，跳过"
    POST_WEEKLY=no
  else
    WEEK_BASE_DATE="${MARK_DATE}"
    WEEK_BASE_STATE="${MARK_STATE}"
  fi
fi

MONTH_BASE_DATE=""
MONTH_BASE_STATE=""
if [ "${POST_MONTHLY}" = yes ]; then
  read_summary_marker monthly
  if [ "${MARK_DATE}" = "${CN_DATE}" ]; then
    info "今天已发过月总结，跳过"
    POST_MONTHLY=no
  else
    MONTH_BASE_DATE="${MARK_DATE}"
    MONTH_BASE_STATE="${MARK_STATE}"
  fi
fi

if [ "${POST_WEEKLY}" = no ] && [ "${POST_MONTHLY}" = no ]; then
  exit 0
fi

SUMMARY_LABEL="月总结"
if [ "${POST_WEEKLY}" = yes ] && [ "${POST_MONTHLY}" = yes ]; then
  SUMMARY_LABEL="周总结和月总结"
elif [ "${POST_WEEKLY}" = yes ]; then
  SUMMARY_LABEL="周总结"
fi

print_summary_section() {
  section_label="$1"
  base_date="$2"
  base_state="$3"
  if [ -z "${base_state}" ]; then
    printf '## %s\n\n首次总结，先记录当前版本：\n' "${section_label}"
    print_current_versions
    return 0
  fi
  diff_state "${base_state}"
  if [ "${DIFF_COUNT}" -eq 0 ]; then
    printf '## %s\n\n自 %s 以来无版本变化。\n\n当前版本：\n' "${section_label}" "${base_date}"
    print_current_versions
  else
    printf '## %s\n\n自 %s 以来：\n%s' "${section_label}" "${base_date}" "${DIFF_LINES}"
  fi
}

SUMMARY_FILE="${tmp}/summary.md"
{
  if [ "${POST_WEEKLY}" = yes ]; then
    printf '<!-- build-summary-state:weekly:%s:%s -->\n' "${CN_DATE}" "${STATE}"
  fi
  if [ "${POST_MONTHLY}" = yes ]; then
    printf '<!-- build-summary-state:monthly:%s:%s -->\n' "${CN_DATE}" "${STATE}"
  fi
  printf '\n@CodeBuddy 请根据下面的%s，整理一份面向使用者的简洁总结，并作为评论发布在这里。\n\n' "${SUMMARY_LABEL}"
  if [ "${POST_WEEKLY}" = yes ]; then
    print_summary_section "${CN_DATE} 周总结" "${WEEK_BASE_DATE}" "${WEEK_BASE_STATE}"
  fi
  if [ "${POST_MONTHLY}" = yes ]; then
    if [ "${POST_WEEKLY}" = yes ]; then
      printf '\n'
    fi
    print_summary_section "${CN_DATE} 月总结" "${MONTH_BASE_DATE}" "${MONTH_BASE_STATE}"
  fi
  printf '\n'
  printf '%s\n' "- 镜像：\`${IMAGE_REF:-unknown}\`"
  printf '%s\n' "- 摘要：\`${DIGEST_SHORT:-${DIGEST:-unknown}}\`"
  printf '%s\n' "- 提交：\`${COMMIT_SHORT}\`"
  print_annotation
} >"${SUMMARY_FILE}"

if cnb issues post-issue-comment \
  --repo "${REPO}" \
  --number "${NUMBER}" \
  --body-file "${SUMMARY_FILE}" \
  >"${tmp}/summary-post.txt" 2>&1; then
  info "✓ 已发布${SUMMARY_LABEL}到 Issue #${NUMBER}"
else
  warn "发布${SUMMARY_LABEL}失败：$(head -n 5 "${tmp}/summary-post.txt" 2>/dev/null | tr '\n' ' ' || true)"
fi

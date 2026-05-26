#!/usr/bin/env bash
# extract_evidence.sh - マーカーを用いたエビデンス自動抽出プログラム

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. config をソース（env var > config の順で上書き）
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/settings.env}"
LOG_FILES=()
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# 2. config にも env var にも無い場合のデフォルト値
: "${MARKERS_FILE:=${SCRIPT_DIR}/markers/test_markers.csv}"
: "${EVIDENCE_DIR:=${SCRIPT_DIR}/evidence}"
: "${EXTRACT_MODE:=strict}"
: "${FALLBACK_LINES:=500}"

# 3. LOG_FILES が未定義でも空配列を保証
LOG_FILES=("${LOG_FILES[@]+"${LOG_FILES[@]}"}")

USE_JOURNALCTL=false
LOG_FILE_ARG=""  # -l オプションで指定された単一ファイル
TARGET_ID=""

# ============================================================
# 関数定義
# ============================================================

usage() {
    cat <<EOF
使用方法: $(basename "$0") [オプション]

オプション:
  -m, --markers  FILE   識別子管理ファイルパス（必須）
  -l, --log      FILE   対象ログファイルパス（config の LOG_FILES より優先）
  -j, --journalctl      journalctl から取得（-l の代わりに使用）
  -o, --output   DIR    エビデンス出力先ディレクトリ
  -e, --mode     MODE   抽出モード: strict | loose（デフォルト: strict）
  -i, --id       ID     特定の試験 ID のみ抽出（省略時は全件）
  -h, --help            このヘルプを表示

ログソースの優先順位:
  1. --journalctl
  2. -l で指定したファイル
  3. config/settings.env の LOG_FILES

複数ファイル時の出力:
  evidence/<TEST_ID>/<ログファイル名>  （ファイルごとに分割）

例:
  $(basename "$0") -m markers/test_markers.csv
  $(basename "$0") -m markers/test_markers.csv -l /var/log/syslog -o evidence/
  $(basename "$0") -m markers/test_markers.csv --journalctl
EOF
}

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# 指定パターンに最初にマッチする行番号を返す
find_marker_line() {
    local content_file="$1" pattern="$2"
    grep -n "${pattern}" "${content_file}" | head -1 | cut -d: -f1
}

# start_line より後に現れる最初のマーカー行番号を返す
find_next_marker_line() {
    local content_file="$1" after_line="$2"
    awk -v sl="${after_line}" \
        'NR > sl && /\[TEST_MARKER_(START|END|ABORT)\]/ { print NR; exit }' \
        "${content_file}"
}

# 1 試験分を抽出してファイルに書き出す
# 戻り値: 0=成功, 1=不完全(終了マーカーなし), 2=開始マーカーなし
extract_for_test() {
    local test_id="$1" content_file="$2" output_file="$3" source_label="$4"
    local start_line end_line abort_line actual_end incomplete=false

    # test_id をgrep正規表現に安全に埋め込むためエスケープ
    local safe_id
    safe_id=$(printf '%s' "${test_id}" | sed 's/[]\[^$.*\\()|+?{}]/\\&/g')

    # 重複検出
    local dup_count
    dup_count=$(grep -c "\[TEST_MARKER_START\].*test_id=${safe_id}" "${content_file}" || true)
    if [[ "${dup_count}" -gt 1 ]]; then
        log_warn "識別子 ${test_id} の開始マーカーが複数存在します（${source_label}）。最初の出現を使用します。"
    fi

    start_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_START\].*test_id=${safe_id}")
    [[ -z "${start_line}" ]] && return 2

    end_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_END\].*test_id=${safe_id}")
    abort_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_ABORT\].*test_id=${safe_id}")

    if [[ -n "${end_line}" ]]; then
        actual_end="${end_line}"
    elif [[ -n "${abort_line}" ]]; then
        actual_end="${abort_line}"
        incomplete=true
    else
        incomplete=true
        if [[ "${EXTRACT_MODE}" == "strict" ]]; then
            local next_line
            next_line=$(find_next_marker_line "${content_file}" "${start_line}")
            if [[ -n "${next_line}" ]]; then
                actual_end=$((next_line - 1))
            else
                actual_end=$((start_line + FALLBACK_LINES))
            fi
        else
            actual_end=$((start_line + FALLBACK_LINES))
        fi
    fi

    mkdir -p "$(dirname "${output_file}")"
    {
        echo "# ========================================"
        echo "# エビデンスログ"
        echo "# 試験ID    : ${test_id}"
        echo "# ソース    : ${source_label}"
        echo "# 抽出日時  : $(date '+%Y-%m-%dT%H:%M:%S')"
        echo "# 抽出モード: ${EXTRACT_MODE}"
        if [[ "${incomplete}" == "true" ]]; then
            echo "# 状態      : 終了マーカーなし（不完全な抽出）"
        fi
        echo "# ========================================"
        sed -n "${start_line},${actual_end}p" "${content_file}"
    } > "${output_file}"

    [[ "${incomplete}" == "true" ]] && return 1
    return 0
}

# ============================================================
# 引数パース
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--markers)    MARKERS_FILE="$2";   shift 2 ;;
        -l|--log)        LOG_FILE_ARG="$2";   shift 2 ;;
        -j|--journalctl) USE_JOURNALCTL=true; shift   ;;
        -o|--output)     EVIDENCE_DIR="$2";   shift 2 ;;
        -e|--mode)       EXTRACT_MODE="$2";   shift 2 ;;
        -i|--id)         TARGET_ID="$2";      shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               log_error "不明なオプション: $1"; usage; exit 1 ;;
    esac
done

# ============================================================
# ログソースの決定
# ============================================================

declare -a LOG_SOURCES=()
declare -a LOG_SOURCE_NAMES=()

if [[ "${USE_JOURNALCTL}" == "true" ]]; then
    LOG_SOURCES=("__journalctl__")
    LOG_SOURCE_NAMES=("journalctl")
elif [[ -n "${LOG_FILE_ARG}" ]]; then
    LOG_SOURCES=("${LOG_FILE_ARG}")
    LOG_SOURCE_NAMES=("$(basename "${LOG_FILE_ARG}")")
elif [[ ${#LOG_FILES[@]} -gt 0 ]]; then
    LOG_SOURCES=("${LOG_FILES[@]}")
    # 同名ファイルがある場合は 親ディレクトリ名_ファイル名 で区別する
    for _f in "${LOG_FILES[@]}"; do
        _base=$(basename "${_f}")
        _dup=0
        for _g in "${LOG_FILES[@]}"; do
            [[ "$(basename "${_g}")" == "${_base}" ]] && _dup=$((_dup + 1))
        done
        if [[ ${_dup} -gt 1 ]]; then
            LOG_SOURCE_NAMES+=("$(basename "$(dirname "${_f}")")_${_base}")
        else
            LOG_SOURCE_NAMES+=("${_base}")
        fi
    done
fi

# ============================================================
# バリデーション
# ============================================================

if [[ ! -f "${MARKERS_FILE}" ]]; then
    log_error "識別子管理ファイルが見つかりません: ${MARKERS_FILE}"
    exit 1
fi

if [[ ${#LOG_SOURCES[@]} -eq 0 ]]; then
    log_error "ログソースが指定されていません。-l, --journalctl、または config/settings.env の LOG_FILES を設定してください。"
    usage
    exit 1
fi

for _src in "${LOG_SOURCES[@]}"; do
    [[ "${_src}" == "__journalctl__" ]] && continue
    if [[ ! -r "${_src}" ]]; then
        log_error "ログファイルにアクセスできません: ${_src}"
        exit 1
    fi
done

MULTI_SOURCE=false
[[ ${#LOG_SOURCES[@]} -gt 1 ]] && MULTI_SOURCE=true

mkdir -p "${EVIDENCE_DIR}"

# ============================================================
# ログ内容を一時ファイルに展開
# ============================================================

declare -a TMPLOG_FILES=()
_cleanup_tmplogs() { rm -f "${TMPLOG_FILES[@]+"${TMPLOG_FILES[@]}"}"; }
trap _cleanup_tmplogs EXIT

for _src in "${LOG_SOURCES[@]}"; do
    _tmp=$(mktemp)
    TMPLOG_FILES+=("${_tmp}")
    if [[ "${_src}" == "__journalctl__" ]]; then
        if ! journalctl -t TEST_MARKER --no-pager > "${_tmp}" 2>/dev/null; then
            log_warn "journalctl の取得に失敗しました。空のログとして処理します。"
        fi
    else
        if ! cat "${_src}" > "${_tmp}"; then
            log_error "ログファイルの読み込みに失敗しました: ${_src}"
            exit 1
        fi
    fi
done

# ============================================================
# メインループ
# ============================================================

log_info "識別子管理ファイル : ${MARKERS_FILE}"
log_info "出力先ディレクトリ : ${EVIDENCE_DIR}"
log_info "抽出モード         : ${EXTRACT_MODE}"
log_info "ログソース         :"
for _n in "${LOG_SOURCE_NAMES[@]}"; do log_info "  - ${_n}"; done
echo ""

TOTAL=0 SUCCESS=0 INCOMPLETE=0 FAILED=0
SUMMARY_FILE="${EVIDENCE_DIR}/summary.txt"

{
    echo "========================================"
    echo "  エビデンス抽出サマリ"
    echo "  実行日時: $(date '+%Y-%m-%dT%H:%M:%S')"
    echo "  ログソース:"
    for _n in "${LOG_SOURCE_NAMES[@]}"; do echo "    - ${_n}"; done
    echo "========================================"
    echo ""
} > "${SUMMARY_FILE}"

while IFS=',' read -r test_id test_name tester start_time end_time status _ev; do
    if [[ -n "${TARGET_ID}" && "${test_id}" != "${TARGET_ID}" ]]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))
    log_info "抽出中: ${test_id} (${test_name:-不明})"
    printf "  %s (%s)\n" "${test_id}" "${test_name:-不明}" >> "${SUMMARY_FILE}"

    _test_success=0
    _test_incomplete=0
    _test_failed=0

    for _i in "${!LOG_SOURCES[@]}"; do
        _src_name="${LOG_SOURCE_NAMES[${_i}]}"
        _tmplog="${TMPLOG_FILES[${_i}]}"

        if [[ "${MULTI_SOURCE}" == "true" ]]; then
            _out_file="${EVIDENCE_DIR}/evidence_${test_id}/${_src_name}"
        else
            _out_file="${EVIDENCE_DIR}/evidence_${test_id}.log"
        fi

        _rc=0
        extract_for_test "${test_id}" "${_tmplog}" "${_out_file}" "${_src_name}" || _rc=$?

        case "${_rc}" in
            0)
                _test_success=$((_test_success + 1))
                log_info "  [OK]         ${_src_name} -> ${_out_file}"
                printf "    [OK]         %-30s -> %s\n" "${_src_name}" "${_out_file##*/evidence_${test_id}/}" \
                    >> "${SUMMARY_FILE}"
                ;;
            1)
                _test_incomplete=$((_test_incomplete + 1))
                log_warn "  [INCOMPLETE] ${_src_name} -> ${_out_file} ※終了マーカーなし"
                printf "    [INCOMPLETE] %-30s -> %s ※終了マーカーなし\n" \
                    "${_src_name}" "${_out_file##*/evidence_${test_id}/}" >> "${SUMMARY_FILE}"
                ;;
            2)
                _test_failed=$((_test_failed + 1))
                log_warn "  [NOT_FOUND]  ${_src_name} -> 開始マーカーなし"
                printf "    [NOT_FOUND]  %-30s -> 開始マーカーが見つかりません\n" \
                    "${_src_name}" >> "${SUMMARY_FILE}"
                ;;
        esac
    done

    # 試験単位の集計
    # 全ソースでマーカーなし → FAILED
    # 一部でもマーカーなし or 終了マーカーなし → INCOMPLETE
    # 全ソース正常 → SUCCESS
    if [[ $_test_failed -eq ${#LOG_SOURCES[@]} ]]; then
        FAILED=$((FAILED + 1))
    elif [[ $_test_incomplete -gt 0 || $_test_failed -gt 0 ]]; then
        INCOMPLETE=$((INCOMPLETE + 1))
    else
        SUCCESS=$((SUCCESS + 1))
    fi
    echo "" >> "${SUMMARY_FILE}"

done < <(tail -n +2 "${MARKERS_FILE}")

{
    echo "----------------------------------------"
    printf "  %-8s : %d\n" "合計"   "${TOTAL}"
    printf "  %-8s : %d\n" "成功"   "${SUCCESS}"
    printf "  %-8s : %d\n" "不完全" "${INCOMPLETE}"
    printf "  %-8s : %d\n" "失敗"   "${FAILED}"
    echo "----------------------------------------"
} >> "${SUMMARY_FILE}"

echo ""
echo "========================================"
echo " 抽出完了"
echo "  合計    : ${TOTAL}"
echo "  成功    : ${SUCCESS}"
echo "  不完全  : ${INCOMPLETE} $([ "${INCOMPLETE}" -gt 0 ] && echo '← 終了マーカーなし' || true)"
echo "  失敗    : ${FAILED}"
echo "  サマリ  : ${SUMMARY_FILE}"
echo "========================================"

[[ "${FAILED}" -gt 0 || "${INCOMPLETE}" -gt 0 ]] && exit 1
exit 0

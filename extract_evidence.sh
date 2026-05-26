#!/usr/bin/env bash
# extract_evidence.sh - マーカーを用いたエビデンス自動抽出プログラム

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/settings.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

MARKERS_FILE="${MARKERS_FILE:-${SCRIPT_DIR}/markers/test_markers.csv}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${SCRIPT_DIR}/evidence}"
EXTRACT_MODE="${EXTRACT_MODE:-strict}"
FALLBACK_LINES="${FALLBACK_LINES:-500}"

USE_JOURNALCTL=false
LOG_FILE=""
TARGET_ID=""

# ============================================================
# 関数定義
# ============================================================

usage() {
    cat <<EOF
使用方法: $(basename "$0") [オプション]

オプション:
  -m, --markers  FILE   識別子管理ファイルパス（必須）
  -l, --log      FILE   対象ログファイルパス
  -j, --journalctl      journalctl から取得（-l の代わりに使用）
  -o, --output   DIR    エビデンス出力先ディレクトリ
  -e, --mode     MODE   抽出モード: strict | loose（デフォルト: strict）
  -i, --id       ID     特定の試験 ID のみ抽出（省略時は全件）
  -h, --help            このヘルプを表示

抽出モード:
  strict  終了マーカーがない場合、次マーカー直前まで抽出
  loose   終了マーカーがない場合、開始マーカーから ${FALLBACK_LINES} 行を抽出

例:
  $(basename "$0") -m markers/test_markers.csv -l /var/log/syslog -o evidence/
  $(basename "$0") -m markers/test_markers.csv --journalctl -o evidence/
  $(basename "$0") -m markers/test_markers.csv -l /var/log/syslog -i TEST_20260526_220000_1234_API
EOF
}

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ログソースの内容を標準出力に書き出す
get_log_content() {
    if [[ "${USE_JOURNALCTL}" == "true" ]]; then
        journalctl -t TEST_MARKER --no-pager 2>/dev/null
    else
        cat "${LOG_FILE}"
    fi
}

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
    local test_id="$1" content_file="$2" output_file="$3"
    local start_line end_line abort_line actual_end incomplete=false

    # 重複検出（開始マーカーが複数ある場合）
    local dup_count
    dup_count=$(grep -c "\[TEST_MARKER_START\].*test_id=${test_id}" "${content_file}" || true)
    if [[ "${dup_count}" -gt 1 ]]; then
        log_warn "識別子 ${test_id} の開始マーカーが複数存在します（重複検出）。最初の出現を使用します。"
    fi

    start_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_START\].*test_id=${test_id}")
    [[ -z "${start_line}" ]] && return 2

    end_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_END\].*test_id=${test_id}")
    abort_line=$(find_marker_line "${content_file}" \
        "\[TEST_MARKER_ABORT\].*test_id=${test_id}")

    if [[ -n "${end_line}" ]]; then
        actual_end="${end_line}"
    elif [[ -n "${abort_line}" ]]; then
        # ABORT マーカーまでを抽出
        actual_end="${abort_line}"
        incomplete=true
    else
        # 終了マーカーなし: モードに従いフォールバック
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

    {
        echo "# ========================================"
        echo "# エビデンスログ"
        echo "# 試験ID    : ${test_id}"
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
        -m|--markers)    MARKERS_FILE="$2";  shift 2 ;;
        -l|--log)        LOG_FILE="$2";       shift 2 ;;
        -j|--journalctl) USE_JOURNALCTL=true; shift   ;;
        -o|--output)     EVIDENCE_DIR="$2";   shift 2 ;;
        -e|--mode)       EXTRACT_MODE="$2";   shift 2 ;;
        -i|--id)         TARGET_ID="$2";      shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               log_error "不明なオプション: $1"; usage; exit 1 ;;
    esac
done

# ============================================================
# バリデーション
# ============================================================

if [[ ! -f "${MARKERS_FILE}" ]]; then
    log_error "識別子管理ファイルが見つかりません: ${MARKERS_FILE}"
    exit 1
fi

if [[ "${USE_JOURNALCTL}" == "false" ]]; then
    if [[ -z "${LOG_FILE}" ]]; then
        log_error "ログファイル (-l) または --journalctl を指定してください。"
        usage
        exit 1
    fi
    if [[ ! -r "${LOG_FILE}" ]]; then
        log_error "ログファイルにアクセスできません: ${LOG_FILE}"
        exit 1
    fi
fi

mkdir -p "${EVIDENCE_DIR}"

# ============================================================
# ログ内容を一時ファイルに展開
# ============================================================

TMPLOG=$(mktemp)
trap 'rm -f "${TMPLOG}"' EXIT

if ! get_log_content > "${TMPLOG}"; then
    log_error "ログの取得に失敗しました。"
    exit 1
fi

# ============================================================
# メインループ
# ============================================================

log_info "識別子管理ファイル : ${MARKERS_FILE}"
log_info "出力先ディレクトリ : ${EVIDENCE_DIR}"
log_info "抽出モード         : ${EXTRACT_MODE}"
echo ""

TOTAL=0 SUCCESS=0 INCOMPLETE=0 FAILED=0
SUMMARY_FILE="${EVIDENCE_DIR}/summary.txt"

{
    echo "========================================"
    echo "  エビデンス抽出サマリ"
    echo "  実行日時: $(date '+%Y-%m-%dT%H:%M:%S')"
    if [[ "${USE_JOURNALCTL}" == "true" ]]; then
        echo "  ログソース: journalctl"
    else
        echo "  ログソース: ${LOG_FILE}"
    fi
    echo "========================================"
    echo ""
} > "${SUMMARY_FILE}"

while IFS=',' read -r test_id test_name tester start_time end_time status _evidence_file_col; do
    if [[ -n "${TARGET_ID}" && "${test_id}" != "${TARGET_ID}" ]]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))
    OUT_FILE="${EVIDENCE_DIR}/evidence_${test_id}.log"
    log_info "抽出中: ${test_id} (${test_name:-不明})"

    extract_rc=0
    extract_for_test "${test_id}" "${TMPLOG}" "${OUT_FILE}" || extract_rc=$?

    case "${extract_rc}" in
        0)
            SUCCESS=$((SUCCESS + 1))
            log_info "  -> 完了: ${OUT_FILE}"
            printf "[OK]          %-45s -> %s\n" \
                "${test_id}" "$(basename "${OUT_FILE}")" >> "${SUMMARY_FILE}"
            ;;
        1)
            INCOMPLETE=$((INCOMPLETE + 1))
            log_warn "  -> 不完全: 終了マーカーなし -> ${OUT_FILE}"
            printf "[INCOMPLETE]  %-45s -> %s ※終了マーカーなし\n" \
                "${test_id}" "$(basename "${OUT_FILE}")" >> "${SUMMARY_FILE}"
            ;;
        2)
            FAILED=$((FAILED + 1))
            log_warn "  -> 失敗: 開始マーカーが見つかりません (${test_id})"
            rm -f "${OUT_FILE}"
            printf "[NOT_FOUND]   %-45s -> 開始マーカーが見つかりません\n" \
                "${test_id}" >> "${SUMMARY_FILE}"
            ;;
    esac
done < <(tail -n +2 "${MARKERS_FILE}")

{
    echo ""
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

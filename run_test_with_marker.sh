#!/usr/bin/env bash
# run_test_with_marker.sh - マーカー出力付き試験実行プログラム

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. config をソース（env var > config の順で上書き）
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/settings.env}"
LOG_FILES=()
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# 2. config にも env var にも無い場合のデフォルト値
: "${LOG_TYPE:=syslog}"
: "${MARKERS_FILE:=${SCRIPT_DIR}/markers/test_markers.csv}"
: "${TESTER:=$(whoami)}"

# 3. LOG_FILES が未定義でも空配列を保証
LOG_FILES=("${LOG_FILES[@]+"${LOG_FILES[@]}"}")

_TEST_ID=""
_TEST_COMPLETED=false

# ============================================================
# 関数定義
# ============================================================

usage() {
    cat <<EOF
使用方法: $(basename "$0") -n <試験名> [オプション] [-- コマンド]

オプション:
  -n, --name      NAME   試験名称（必須）
  -t, --tester    USER   実施者名（省略時: OS ユーザー名）
  -l, --log-type  TYPE   ログ種別: syslog | journald | file | stdout
                         （デフォルト: syslog）
  -f, --log-file  PATH   LOG_TYPE=file 時の出力先ファイルパス
  -m, --markers   PATH   識別子管理ファイルパス
  -h, --help             このヘルプを表示

コマンド指定:
  -- に続けてコマンドを記述します。複数コマンドは && や ; で連結するか、
  シェルスクリプトを渡してください。

例:
  $(basename "$0") -n "API疎通試験" -- curl -s http://localhost:8080/health
  $(basename "$0") -n "MQTT接続確認" -t yamada -- ./scenario_mqtt.sh
  $(basename "$0") -n "複合試験" -- "cmd1 && cmd2"
EOF
}

# 一意な試験識別子を生成する
# 形式: TEST_YYYYMMDD_HHMMSS_PID_SLUG
generate_test_id() {
    local name="$1"
    local dt pid slug
    dt=$(date +%Y%m%d_%H%M%S)
    pid=$$
    if [[ -n "${name}" ]]; then
        slug=$(echo "${name}" | tr -cs 'a-zA-Z0-9' '_' | cut -c1-8 | sed 's/_*$//')
        echo "TEST_${dt}_${pid}_${slug}"
    else
        echo "TEST_${dt}_${pid}"
    fi
}

# ログソースにマーカー文字列を書き込む（LOG_TYPE=file 時は LOG_FILES 全件に書く）
write_marker() {
    local message="$1"
    local ret=0
    case "${LOG_TYPE}" in
        syslog|journald)
            logger -t TEST_MARKER "${message}"
            ret=$?
            ;;
        file)
            if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
                echo "[ERROR] LOG_FILES が設定されていません。config/settings.env を確認してください。" >&2
                return 1
            fi
            local ts
            ts=$(date '+%Y-%m-%dT%H:%M:%S')
            for target in "${LOG_FILES[@]}"; do
                echo "${ts} TEST_MARKER: ${message}" >> "${target}" || ret=1
            done
            ;;
        stdout|*)
            echo "$(date '+%Y-%m-%dT%H:%M:%S') TEST_MARKER: ${message}"
            ;;
    esac
    if [[ ${ret} -ne 0 ]]; then
        echo "[ERROR] マーカーの書き込みに失敗しました (LOG_TYPE=${LOG_TYPE})" >&2
        return 1
    fi
    return 0
}

# 管理ファイルを初期化する（存在しない場合のみヘッダを書く）
init_markers_file() {
    mkdir -p "$(dirname "${MARKERS_FILE}")"
    if [[ ! -f "${MARKERS_FILE}" ]]; then
        echo "test_id,test_name,tester,start_time,end_time,status,evidence_file" \
            > "${MARKERS_FILE}"
    fi
}

# 管理ファイルに 1 レコードを追記する
append_markers_record() {
    local test_id="$1" test_name="$2" tester="$3" start_time="$4" \
          end_time="${5:-}" status="${6:-}" evidence_file="${7:-}"
    echo "${test_id},${test_name},${tester},${start_time},${end_time},${status},${evidence_file}" \
        >> "${MARKERS_FILE}"
}

# 管理ファイルの該当 test_id 行を更新する
update_markers_record() {
    local test_id="$1" end_time="$2" status="$3"
    [[ ! -f "${MARKERS_FILE}" ]] && return 1
    local tmp
    tmp=$(mktemp)
    awk -F',' -v OFS=',' -v id="${test_id}" -v et="${end_time}" -v st="${status}" '
        NR == 1 { print; next }
        $1 == id { $5 = et; $6 = st; print; next }
        { print }
    ' "${MARKERS_FILE}" > "${tmp}" && mv "${tmp}" "${MARKERS_FILE}"
}

# EXIT / INT / TERM 時の共通クリーンアップ
on_exit() {
    if [[ "${_TEST_COMPLETED}" == "false" && -n "${_TEST_ID}" ]]; then
        local abort_time
        abort_time=$(date '+%Y-%m-%dT%H:%M:%S')
        write_marker \
            "[TEST_MARKER_ABORT] test_id=${_TEST_ID} status=ABORT time=${abort_time}" \
            2>/dev/null || true
        update_markers_record "${_TEST_ID}" "${abort_time}" "ABORT" 2>/dev/null || true
        echo "" >&2
        echo "[異常終了] test_id=${_TEST_ID} は ABORT として記録されました。" >&2
    fi
}

# ============================================================
# 引数パース
# ============================================================

TEST_NAME=""
CMD_STRING=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)      TEST_NAME="$2";    shift 2 ;;
        -t|--tester)    TESTER="$2";       shift 2 ;;
        -l|--log-type)  LOG_TYPE="$2";     shift 2 ;;
        -f|--log-file)  LOG_FILE="$2";     shift 2 ;;
        -m|--markers)   MARKERS_FILE="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; CMD_STRING="$*"; break ;;
        -*)             echo "[ERROR] 不明なオプション: $1" >&2; usage; exit 1 ;;
        *)              echo "[ERROR] 予期しない引数: $1" >&2;  usage; exit 1 ;;
    esac
done

if [[ -z "${TEST_NAME}" ]]; then
    echo "[ERROR] 試験名 (-n) は必須です。" >&2
    usage
    exit 1
fi

# ============================================================
# メインロジック
# ============================================================

trap on_exit EXIT INT TERM

_TEST_ID=$(generate_test_id "${TEST_NAME}")
START_TIME=$(date '+%Y-%m-%dT%H:%M:%S')

# 開始マーカー出力
if ! write_marker \
    "[TEST_MARKER_START] test_id=${_TEST_ID} test_name=${TEST_NAME} tester=${TESTER} start_time=${START_TIME}"; then
    echo "[WARN] 開始マーカーの出力に失敗しました。管理ファイルへの記録は継続します。" >&2
fi

init_markers_file
append_markers_record "${_TEST_ID}" "${TEST_NAME}" "${TESTER}" "${START_TIME}"

echo "========================================"
echo " 試験開始"
echo "  試験名   : ${TEST_NAME}"
echo "  試験ID   : ${_TEST_ID}"
echo "  実施者   : ${TESTER}"
echo "  開始時刻 : ${START_TIME}"
if [[ "${LOG_TYPE}" == "file" && ${#LOG_FILES[@]} -gt 0 ]]; then
    echo "  対象ログ :"
    for _f in "${LOG_FILES[@]}"; do echo "    - ${_f}"; done
fi
echo "========================================"

# コマンド実行 / 手動操作待ち
OVERALL_STATUS="OK"

if [[ -n "${CMD_STRING}" ]]; then
    echo ""
    echo "--- コマンド実行 ---"
    echo "[実行] ${CMD_STRING}"
    if ! (eval "${CMD_STRING}"); then
        FAIL_TIME=$(date '+%Y-%m-%dT%H:%M:%S')
        echo "[失敗] コマンド: ${CMD_STRING}  時刻: ${FAIL_TIME}" >&2
        OVERALL_STATUS="NG"
    fi
else
    echo ""
    echo "試験を実施してください。"
    echo "  完了 → Enter"
    echo "  失敗 → f + Enter"
    echo "  中断 → Ctrl+C"
    echo ""
    read -r -p "> " _INPUT
    if [[ "${_INPUT}" == "f" || "${_INPUT}" == "F" ]]; then
        OVERALL_STATUS="NG"
    fi
fi

END_TIME=$(date '+%Y-%m-%dT%H:%M:%S')

# 終了マーカー出力
if ! write_marker \
    "[TEST_MARKER_END] test_id=${_TEST_ID} status=${OVERALL_STATUS} end_time=${END_TIME}"; then
    echo "[WARN] 終了マーカーの出力に失敗しました。" >&2
fi

update_markers_record "${_TEST_ID}" "${END_TIME}" "${OVERALL_STATUS}"

echo ""
echo "========================================"
echo " 試験終了"
echo "  試験ID   : ${_TEST_ID}"
echo "  終了時刻 : ${END_TIME}"
echo "  結果     : ${OVERALL_STATUS}"
echo "========================================"
echo ""
echo "次のステップ:"
echo "  エビデンス抽出: ./extract_evidence.sh -m ${MARKERS_FILE} -l <ログファイルパス>"
echo "  試験ID         : ${_TEST_ID}"

_TEST_COMPLETED=true
trap - EXIT INT TERM
exit 0

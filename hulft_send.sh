#!/usr/bin/env bash
# =============================================================================
# hulft_send.sh  - HULFT送信ラッパースクリプト
#
# 設計方針:
#   - 各処理を独立した関数に分割し、単体テストを容易にする
#   - 外部コマンド(utlsend/utllist)はラッパー関数経由で呼び出し、
#     テスト時はスタブ関数で差し替え可能にする
#   - 設定ファイルは source で読み込み、テスト時は差し替え可能
#   - main() を末尾で呼び出す構造にし、テスト時は source のみで関数をロード可能
# =============================================================================
set -uo pipefail
# 注意: -e (errexit) は意図的に省略。
#       各関数が戻り値で明示的にエラー制御しているため、
#       -e を有効にすると非ゼロ戻り値の正常系処理（should_retry 等）が
#       予期せず終了する可能性がある。

# --- スクリプト自身のディレクトリ（設定ファイルの相対パス解決に使用）--------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 設定ファイルパス（テスト時は上書き可能）---------------------------------
: "${CONFIG_FILE:="${SCRIPT_DIR}/hulft_send.conf"}"

# =============================================================================
# 定数
# =============================================================================
readonly EXIT_OK=0
readonly EXIT_ERR_PARAM=1      # パラメータ不正
readonly EXIT_ERR_CONFIG=2     # 設定ファイル不正
readonly EXIT_ERR_UTLSEND=3    # utlsend 失敗
readonly EXIT_ERR_UTLLIST=4    # utllist 失敗
readonly EXIT_ERR_RETRY_OVER=5 # リトライ上限超過

# =============================================================================
# ログ関数
# =============================================================================
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# =============================================================================
# 設定ファイル読み込み
# =============================================================================
# 設定ファイルで定義する変数:
#   DEFAULT_TIMEOUT      - 同期タイムアウトのデフォルト値（秒）
#   RETRY_COUNT          - リトライ回数
#   RETRY_INTERVAL       - リトライ間隔（秒）
#   RETRY_COMPLETE_CODES - リトライ対象の完了コード（スペース区切り）
#   RETRY_DETAIL_CODES   - リトライ対象の詳細コード（スペース区切り）
# =============================================================================
load_config() {
    local config_file="${1:-$CONFIG_FILE}"

    if [[ ! -f "$config_file" ]]; then
        log_error "設定ファイルが見つかりません: $config_file"
        return $EXIT_ERR_CONFIG
    fi

    # shellcheck source=/dev/null
    source "$config_file" || {
        log_error "設定ファイルの読み込みに失敗しました: $config_file"
        return $EXIT_ERR_CONFIG
    }

    # 必須設定値の確認
    local required_vars=(DEFAULT_TIMEOUT RETRY_COUNT RETRY_INTERVAL
                         RETRY_COMPLETE_CODES RETRY_DETAIL_CODES)
    local var
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var+x}" ]]; then
            log_error "設定ファイルに必須変数が定義されていません: $var"
            return $EXIT_ERR_CONFIG
        fi
    done

    return $EXIT_OK
}

# =============================================================================
# パラメータ解析
# =============================================================================
# 出力（グローバル変数にセット）:
#   PARAM_SYSTEM_ID   - システムID
#   PARAM_HULFT_ID    - HULFTID
#   PARAM_FILE_PATH   - 送信ファイルパス
#   PARAM_SYNC        - 同期フラグ (1=同期, 0=非同期)
#   PARAM_TIMEOUT     - タイムアウト秒（同期時のみ意味を持つ）
# =============================================================================
parse_params() {
    PARAM_SYSTEM_ID=""
    PARAM_HULFT_ID=""
    PARAM_FILE_PATH=""
    PARAM_SYNC=1      # デフォルト: 同期
    PARAM_TIMEOUT=""  # 未指定 → load_config 後にデフォルト値を適用

    local opt
    while [[ $# -gt 0 ]]; do
        opt="$1"
        case "$opt" in
            -s|--system-id)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    log_error "$opt に値が指定されていません"
                    return $EXIT_ERR_PARAM
                fi
                PARAM_SYSTEM_ID="$2"; shift 2 ;;
            -f|--hulft-id)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    log_error "$opt に値が指定されていません"
                    return $EXIT_ERR_PARAM
                fi
                PARAM_HULFT_ID="$2"; shift 2 ;;
            --file)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    log_error "$opt に値が指定されていません"
                    return $EXIT_ERR_PARAM
                fi
                PARAM_FILE_PATH="$2"; shift 2 ;;
            --async)
                PARAM_SYNC=0; shift ;;
            --sync)
                PARAM_SYNC=1; shift ;;
            -w|--timeout)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    log_error "$opt に値が指定されていません"
                    return $EXIT_ERR_PARAM
                fi
                PARAM_TIMEOUT="$2"; shift 2 ;;
            *)
                log_error "不明なオプション: $opt"
                return $EXIT_ERR_PARAM ;;
        esac
    done

    return $EXIT_OK
}

# =============================================================================
# パラメータ検証
# =============================================================================
validate_params() {
    local system_id="$1"
    local hulft_id="$2"
    local file_path="$3"
    local timeout="${4:-}"

    local rc=$EXIT_OK

    if [[ -z "$system_id" ]]; then
        log_error "システムIDは必須です (-s/--system-id)"
        rc=$EXIT_ERR_PARAM
    fi

    if [[ -z "$hulft_id" ]]; then
        log_error "HULFTIDは必須です (-f/--hulft-id)"
        rc=$EXIT_ERR_PARAM
    fi

    if [[ -z "$file_path" ]]; then
        log_error "送信ファイルパスは必須です (--file)"
        rc=$EXIT_ERR_PARAM
    elif [[ ! -f "$file_path" ]]; then
        log_error "送信ファイルが存在しません: $file_path"
        rc=$EXIT_ERR_PARAM
    fi

    if [[ -n "$timeout" ]] && ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        log_error "タイムアウトは正の整数で指定してください: $timeout"
        rc=$EXIT_ERR_PARAM
    fi

    return $rc
}

# =============================================================================
# デフォルト値の適用
# =============================================================================
apply_defaults() {
    local -n _timeout=$1   # nameref

    if [[ -z "$_timeout" ]]; then
        _timeout="${DEFAULT_TIMEOUT:-300}"
    fi
}

# =============================================================================
# 外部コマンドラッパー（テスト時はこれらをスタブで上書きする）
# =============================================================================
run_utlsend() {
    utlsend "$@"
}

run_utllist() {
    utllist "$@"
}

# スリープもラッパー化（テスト時に即時スキップ可能）
run_sleep() {
    sleep "$@"
}

# =============================================================================
# utlsend 呼び出し
# =============================================================================
# 引数:
#   $1 - HULFTID
#   $2 - 送信ファイルパス
#   $3 - 同期フラグ (1=同期, 0=非同期)
#   $4 - タイムアウト（同期時のみ使用）
# 戻り値:
#   utlsend の終了コード
# =============================================================================
invoke_utlsend() {
    local hulft_id="$1"
    local file_path="$2"
    local sync_flag="$3"
    local timeout="$4"

    local -a cmd=( -f "$hulft_id" -file "$file_path" )

    if [[ "$sync_flag" -eq 1 ]]; then
        cmd+=( -sync -w "$timeout" )
    fi

    log_info "utlsend 実行: utlsend ${cmd[*]}"
    run_utlsend "${cmd[@]}"
    local rc=$?

    log_info "utlsend 終了コード: $rc"
    return $rc
}

# =============================================================================
# utlsend 実行前の基準日時取得
# =============================================================================
# utllist のレコード日時と比較するための基準日時を取得する。
# utlsend 呼び出し直前に実行すること。
#
# 出力形式: "YYYYMMDD HHMMSS"  例: "20260529 153000"
# =============================================================================
capture_send_time() {
    date '+%Y%m%d %H%M%S'
}

# =============================================================================
# utllist 結果解析
# =============================================================================
# 標準入力から utllist の出力を受け取り、最新レコードの
# 完了コードと詳細コードを出力する。
# レコードの開始日時が基準日時より新しいことも検証する。
#
# 引数:
#   $1 - 基準日時文字列 "YYYYMMDD HHMMSS"（utlsend 前に取得した日時）
#        省略または空文字の場合は日時チェックをスキップする
#
# 出力形式: "<完了コード> <詳細コード>"  例: "0000 0000"
#           解析失敗時は空文字を返し、戻り値 1
#
# utllist 出力形式（ヘッダー行を除いたデータ行）:
#   FILEID  HOSTNAME  DATE  START_TIME  END_TIME  RECORDS  STATUS  CONNECT
#   DATE      フィールド（3列目）: YYYYMMDD 形式
#   START_TIME フィールド（4列目）: HHMMSS 形式
#   STATUS    フィールド（7列目）: "完了コード-詳細コード" 形式
# =============================================================================
parse_utllist_output() {
    local send_time="${1:-}"  # 基準日時（省略可）

    local input
    input="$(cat)"  # 標準入力をすべて読む

    # ヘッダー行とブランク行を除外し、最終データ行を取得
    local last_line
    last_line=$(echo "$input" \
        | grep -v -E '^\s*$|^FILEID' \
        | tail -1)

    if [[ -z "$last_line" ]]; then
        log_warn "utllist の出力からデータ行を取得できませんでした"
        return 1
    fi

    # --- 日時チェック ---------------------------------------------------
    # send_time が指定されている場合のみ検証する
    if [[ -n "$send_time" ]]; then
        # DATE（3列目）と START_TIME（4列目）を結合して "YYYYMMDDHHMMSS" の数値文字列を作る
        local record_datetime
        record_datetime=$(echo "$last_line" | awk '{print $3 $4}')

        # 基準日時も同じ形式（空白除去）に変換
        local send_datetime
        send_datetime="${send_time// /}"  # "YYYYMMDD HHMMSS" → "YYYYMMDDHHMMSS"

        # 形式チェック（14桁の数字であること）
        if ! [[ "$record_datetime" =~ ^[0-9]{14}$ ]]; then
            log_warn "utllist レコードの日時フィールドの形式が不正です: '$record_datetime'"
            return 1
        fi

        # 数値比較：レコード日時 > 基準日時 であること
        if [[ "$record_datetime" -le "$send_datetime" ]]; then
            log_warn "utllist のレコード日時 ($record_datetime) が送信前の基準日時 ($send_datetime) 以前です。古いレコードの可能性があります"
            return 1
        fi

        log_info "日時チェック OK: レコード日時=${record_datetime}, 基準日時=${send_datetime}"
    fi

    # --- STATUS フィールド（7列目）を取得し "CCCC-DDDD" を分割 ----------
    local status_field
    status_field=$(echo "$last_line" | awk '{print $7}')

    if ! [[ "$status_field" =~ ^([0-9A-Za-z]+)-([0-9A-Za-z]+)$ ]]; then
        log_warn "STATUSフィールドの形式が不正です: '$status_field'"
        return 1
    fi

    local complete_code="${BASH_REMATCH[1]}"
    local detail_code="${BASH_REMATCH[2]}"

    echo "${complete_code} ${detail_code}"
    return 0
}

# =============================================================================
# utllist 呼び出しとコード取得
# =============================================================================
# 引数:
#   $1 - HULFTID
#   $2 - 基準日時文字列 "YYYYMMDD HHMMSS"（utlsend 前に capture_send_time で取得）
#        省略または空文字の場合は日時チェックをスキップする
# 出力（名前参照引数でセット）:
#   $3 - complete_code_ref  完了コード
#   $4 - detail_code_ref    詳細コード
# 戻り値:
#   0: 成功, $EXIT_ERR_UTLLIST: 失敗
# =============================================================================
get_delivery_status() {
    local hulft_id="$1"
    local send_time="${2:-}"
    local -n _complete_code=$3
    local -n _detail_code=$4

    log_info "utllist 実行: utllist -s -f $hulft_id"

    local utllist_output
    utllist_output=$(run_utllist -s -f "$hulft_id" 2>&1)
    local utllist_rc=$?

    if [[ $utllist_rc -ne 0 ]]; then
        log_error "utllist が失敗しました (rc=$utllist_rc)"
        return $EXIT_ERR_UTLLIST
    fi

    local parsed
    parsed=$(echo "$utllist_output" | parse_utllist_output "$send_time")
    if [[ $? -ne 0 ]]; then
        log_error "utllist 出力の解析に失敗しました"
        return $EXIT_ERR_UTLLIST
    fi

    _complete_code=$(echo "$parsed" | awk '{print $1}')
    _detail_code=$(echo "$parsed"   | awk '{print $2}')

    log_info "配信ステータス: 完了コード=${_complete_code}, 詳細コード=${_detail_code}"
    return $EXIT_OK
}

# =============================================================================
# リトライ判定
# =============================================================================
# 引数:
#   $1 - 完了コード
#   $2 - 詳細コード
#   $3 - リトライ対象完了コード一覧（スペース区切り。省略時はグローバル変数を使用）
#   $4 - リトライ対象詳細コード一覧（スペース区切り。省略時はグローバル変数を使用）
# 戻り値:
#   0: リトライ対象, 1: リトライ不要（正常 or 回復不可能エラー）
# =============================================================================
should_retry() {
    local complete_code="$1"
    local detail_code="$2"
    local retry_complete_codes="${3:-${RETRY_COMPLETE_CODES:-}}"
    local retry_detail_codes="${4:-${RETRY_DETAIL_CODES:-}}"

    local code
    for code in $retry_complete_codes; do
        if [[ "$complete_code" == "$code" ]]; then
            log_info "完了コード $complete_code はリトライ対象です"
            return 0
        fi
    done

    for code in $retry_detail_codes; do
        if [[ "$detail_code" == "$code" ]]; then
            log_info "詳細コード $detail_code はリトライ対象です"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# 送信処理（リトライループ込み）
# =============================================================================
# 引数:
#   $1 - HULFTID
#   $2 - 送信ファイルパス
#   $3 - 同期フラグ
#   $4 - タイムアウト
# 戻り値:
#   $EXIT_OK            : 成功
#   $EXIT_ERR_UTLSEND   : utlsend 失敗
#   $EXIT_ERR_UTLLIST   : utllist 失敗
#   $EXIT_ERR_RETRY_OVER: リトライ上限超過
# =============================================================================
run_send_with_retry() {
    local hulft_id="$1"
    local file_path="$2"
    local sync_flag="$3"
    local timeout="$4"

    local attempt=0
    local max_attempts=$(( RETRY_COUNT + 1 ))  # 初回 + リトライ回数

    while [[ $attempt -lt $max_attempts ]]; do
        if [[ $attempt -gt 0 ]]; then
            log_info "リトライ $attempt/$RETRY_COUNT (${RETRY_INTERVAL}秒後)"
            run_sleep "$RETRY_INTERVAL"
        fi

        attempt=$(( attempt + 1 ))
        log_info "送信試行 $attempt/$max_attempts 開始"

        # utlsend 呼び出し前に基準日時を取得（utllist の日時チェックに使用）
        local send_time
        send_time=$(capture_send_time)
        log_info "送信前基準日時: ${send_time}"

        # utlsend 呼び出し
        invoke_utlsend "$hulft_id" "$file_path" "$sync_flag" "$timeout"
        local send_rc=$?

        if [[ $send_rc -ne 0 ]]; then
            log_warn "utlsend が非ゼロで終了しました (rc=$send_rc)"
            # リトライ上限に達していれば即終了
            if [[ $attempt -ge $max_attempts ]]; then
                log_error "リトライ上限($RETRY_COUNT)に達しました。utlsend rc=$send_rc"
                return $EXIT_ERR_RETRY_OVER
            fi
            # 上限未達であれば次のループでリトライ
            continue
        fi

        # 非同期モードはステータス確認不要
        if [[ "$sync_flag" -eq 0 ]]; then
            log_info "非同期モード: 送信要求完了"
            return $EXIT_OK
        fi

        # 同期モード: 完了コード/詳細コードを取得してリトライ判定
        local complete_code detail_code
        get_delivery_status "$hulft_id" "$send_time" complete_code detail_code
        local status_rc=$?

        if [[ $status_rc -ne 0 ]]; then
            return $EXIT_ERR_UTLLIST
        fi

        # 正常コードであれば完了
        if ! should_retry "$complete_code" "$detail_code"; then
            log_info "配信成功: 完了コード=${complete_code}, 詳細コード=${detail_code}"
            return $EXIT_OK
        fi

        # リトライ対象だが上限に達している場合
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "リトライ上限($RETRY_COUNT)に達しました。" \
                      "完了コード=${complete_code}, 詳細コード=${detail_code}"
            return $EXIT_ERR_RETRY_OVER
        fi
    done
}

# =============================================================================
# 使用方法
# =============================================================================
usage() {
    cat <<EOF
使用方法: $(basename "$0") [オプション]

必須オプション:
  -s, --system-id  <ID>    システムID
  -f, --hulft-id   <ID>    HULFTID
  --file           <PATH>  送信ファイルパス

任意オプション:
  --sync                   同期モード（デフォルト）
  --async                  非同期モード
  -w, --timeout    <SEC>   同期タイムアウト秒（省略時: 設定ファイルのデフォルト値）

設定ファイル: ${CONFIG_FILE}
EOF
}

# =============================================================================
# main
# =============================================================================
main() {
    # -- 引数なしはヘルプ表示
    if [[ $# -eq 0 ]]; then
        usage
        exit $EXIT_ERR_PARAM
    fi

    # -- パラメータ解析
    parse_params "$@" || exit $EXIT_ERR_PARAM

    # -- 設定ファイル読み込み
    load_config "$CONFIG_FILE" || exit $EXIT_ERR_CONFIG

    # -- デフォルト値適用
    apply_defaults PARAM_TIMEOUT

    # -- パラメータ検証
    validate_params \
        "$PARAM_SYSTEM_ID" \
        "$PARAM_HULFT_ID"  \
        "$PARAM_FILE_PATH" \
        "$PARAM_TIMEOUT"   \
    || exit $EXIT_ERR_PARAM

    log_info "処理開始: システムID=${PARAM_SYSTEM_ID}, HULFTID=${PARAM_HULFT_ID}, ファイル=${PARAM_FILE_PATH}, 同期=${PARAM_SYNC}, タイムアウト=${PARAM_TIMEOUT}"

    # -- 送信（リトライ込み）
    run_send_with_retry \
        "$PARAM_HULFT_ID"  \
        "$PARAM_FILE_PATH" \
        "$PARAM_SYNC"      \
        "$PARAM_TIMEOUT"
    local rc=$?

    log_info "処理終了: rc=$rc"
    exit $rc
}

# =============================================================================
# テスト用に source された場合は main() を呼び出さない
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
#!/usr/bin/env bash
# =============================================================================
# test_hulft_send.sh  - hulft_send.sh 単体テスト
#
# 実行方法:
#   bash test_hulft_send.sh
#
# テスト方針:
#   - hulft_send.sh を source して関数単位でテスト
#   - utlsend/utllist/sleep はスタブ関数で差し替え
#   - 設定ファイルはテスト用のインメモリ変数で代用
#   - テスト間の干渉を防ぐため setUp/tearDown パターンを採用
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/hulft_send.sh"

# =============================================================================
# テストフレームワーク（最小実装）
# =============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  [PASS] $label"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        FAILED_TESTS+=("$label")
        echo "  [FAIL] $label"
        echo "         expected: '$expected'"
        echo "         actual:   '$actual'"
    fi
}

assert_rc() {
    local label="$1"
    local expected_rc="$2"
    local actual_rc="$3"
    assert_eq "$label (exit code)" "$expected_rc" "$actual_rc"
}

run_test() {
    local test_name="$1"
    echo "▶ $test_name"
    "$test_name"
    echo ""
}

print_summary() {
    echo "============================================="
    echo "テスト結果: ${TESTS_RUN}件実行, ${TESTS_PASSED}件成功, ${TESTS_FAILED}件失敗"
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo "失敗したテスト:"
        local t
        for t in "${FAILED_TESTS[@]}"; do
            echo "  - $t"
        done
    fi
    echo "============================================="
}

# =============================================================================
# テスト共通セットアップ
# =============================================================================

# テスト用設定を直接変数にセット（設定ファイル読み込みを使わない）
load_test_config() {
    DEFAULT_TIMEOUT=300
    RETRY_COUNT=2
    RETRY_INTERVAL=0   # テスト高速化のため0秒
    RETRY_COMPLETE_CODES="0250 0251"
    RETRY_DETAIL_CODES="0301 0302"
}

# スタブのリセット
reset_stubs() {
    STUB_UTLSEND_RC=0
    STUB_UTLSEND_CALL_COUNT=0
    STUB_UTLLIST_OUTPUT=""
    STUB_UTLLIST_RC=0
    STUB_SLEEP_CALL_COUNT=0
}

# hulft_send.sh を source（main は呼ばれない）
source "$TARGET_SCRIPT"

# =============================================================================
# スタブ関数定義（テスト時に外部コマンドを差し替え）
# =============================================================================
run_utlsend() {
    STUB_UTLSEND_CALL_COUNT=$(( STUB_UTLSEND_CALL_COUNT + 1 ))
    return "${STUB_UTLSEND_RC:-0}"
}

run_utllist() {
    echo "${STUB_UTLLIST_OUTPUT}"
    return "${STUB_UTLLIST_RC:-0}"
}

run_sleep() {
    STUB_SLEEP_CALL_COUNT=$(( STUB_SLEEP_CALL_COUNT + 1 ))
    # sleep は実行しない
}

# =============================================================================
# テスト: validate_params
# =============================================================================
test_validate_params_all_valid() {
    local tmpfile
    tmpfile=$(mktemp)
    local rc

    validate_params "SYS01" "HULFT01" "$tmpfile" "60"
    rc=$?
    assert_rc "全パラメータ正常" 0 $rc

    rm -f "$tmpfile"
}

test_validate_params_missing_system_id() {
    local tmpfile
    tmpfile=$(mktemp)
    local rc

    validate_params "" "HULFT01" "$tmpfile" "60" 2>/dev/null
    rc=$?
    assert_rc "システムID未指定はエラー" 1 $rc

    rm -f "$tmpfile"
}

test_validate_params_missing_hulft_id() {
    local tmpfile
    tmpfile=$(mktemp)
    local rc

    validate_params "SYS01" "" "$tmpfile" "60" 2>/dev/null
    rc=$?
    assert_rc "HULFTID未指定はエラー" 1 $rc

    rm -f "$tmpfile"
}

test_validate_params_missing_file() {
    local rc
    validate_params "SYS01" "HULFT01" "" "60" 2>/dev/null
    rc=$?
    assert_rc "ファイルパス未指定はエラー" 1 $rc
}

test_validate_params_file_not_exist() {
    local rc
    validate_params "SYS01" "HULFT01" "/nonexistent/file.dat" "60" 2>/dev/null
    rc=$?
    assert_rc "存在しないファイルはエラー" 1 $rc
}

test_validate_params_invalid_timeout() {
    local tmpfile
    tmpfile=$(mktemp)
    local rc

    validate_params "SYS01" "HULFT01" "$tmpfile" "abc" 2>/dev/null
    rc=$?
    assert_rc "タイムアウトが数値でない場合はエラー" 1 $rc

    rm -f "$tmpfile"
}

test_validate_params_timeout_empty_is_ok() {
    local tmpfile
    tmpfile=$(mktemp)
    local rc

    validate_params "SYS01" "HULFT01" "$tmpfile" "" 2>/dev/null
    rc=$?
    assert_rc "タイムアウト空文字（省略）は正常" 0 $rc

    rm -f "$tmpfile"
}

# =============================================================================
# テスト: parse_params
# =============================================================================
test_parse_params_all_options() {
    local rc
    parse_params -s SYS01 -f HULFTID01 --file /tmp/test.dat --sync -w 120
    rc=$?
    assert_rc "parse_params 全オプション 終了コード" 0 $rc
    assert_eq "システムID" "SYS01" "$PARAM_SYSTEM_ID"
    assert_eq "HULFTID" "HULFTID01" "$PARAM_HULFT_ID"
    assert_eq "ファイルパス" "/tmp/test.dat" "$PARAM_FILE_PATH"
    assert_eq "同期フラグ" "1" "$PARAM_SYNC"
    assert_eq "タイムアウト" "120" "$PARAM_TIMEOUT"
}

test_parse_params_async() {
    parse_params -s SYS01 -f HID --file /tmp/f.dat --async 2>/dev/null
    assert_eq "非同期フラグ" "0" "$PARAM_SYNC"
}

test_parse_params_default_sync() {
    parse_params -s SYS01 -f HID --file /tmp/f.dat 2>/dev/null
    assert_eq "デフォルトは同期" "1" "$PARAM_SYNC"
}

test_parse_params_unknown_option() {
    local rc
    parse_params --unknown-opt 2>/dev/null
    rc=$?
    assert_rc "不明なオプションはエラー" 1 $rc
}

# =============================================================================
# テスト: apply_defaults
# =============================================================================
test_apply_defaults_sets_timeout_when_empty() {
    load_test_config
    local timeout=""
    apply_defaults timeout
    assert_eq "タイムアウトにデフォルト値が設定される" "300" "$timeout"
}

test_apply_defaults_keeps_existing_timeout() {
    load_test_config
    local timeout="120"
    apply_defaults timeout
    assert_eq "既存のタイムアウト値は変更されない" "120" "$timeout"
}

# =============================================================================
# テスト: parse_utllist_output
# =============================================================================
test_parse_utllist_normal() {
    local input
    input="FILEID    HOST NAME START DAY   START TIME END TIME   RECORDS  STATUS   CONNECT
TEST1     SUN01.HO  2014/12/10  17:23:52   17:23:52          0 0250-0301   LAN
TEST1     SUN01.HO  2014/12/11  17:52:17   17:52:18       1200 0000-0000   LAN"

    local result rc
    result=$(echo "$input" | parse_utllist_output)
    rc=$?
    assert_rc "parse_utllist_output 正常終了" 0 $rc
    assert_eq "parse_utllist_output 結果" "0000 0000" "$result"
}

test_parse_utllist_picks_last_line() {
    local input
    input="FILEID    HOST NAME START DAY   START TIME END TIME   RECORDS  STATUS   CONNECT
TEST1     SUN01.HO  2014/12/10  17:23:52   17:23:52          0 0250-0301   LAN
TEST1     SUN01.HO  2014/12/11  17:52:17   17:52:18       1200 0000-0000   LAN"

    local result
    result=$(echo "$input" | parse_utllist_output)
    # 最終行の STATUS を取得できているか
    assert_eq "最終行のSTATUSを取得" "0000 0000" "$result"
}

test_parse_utllist_retry_target_code() {
    local input
    input="FILEID    HOST NAME START DAY   START TIME END TIME   RECORDS  STATUS   CONNECT
TEST1     SUN01.HO  2014/12/10  17:23:52   17:23:52          0 0250-0301   LAN"

    local result rc
    result=$(echo "$input" | parse_utllist_output)
    rc=$?
    assert_rc "リトライ対象コード解析" 0 $rc
    assert_eq "リトライ対象コード値" "0250 0301" "$result"
}

test_parse_utllist_empty_input() {
    local rc
    echo "" | parse_utllist_output 2>/dev/null
    rc=$?
    assert_rc "空入力は失敗" 1 $rc
}

test_parse_utllist_invalid_status_format() {
    local input="TEST1  HOST  2024/01/01  10:00:00  10:00:01  100 INVALID  LAN"
    local rc
    echo "$input" | parse_utllist_output 2>/dev/null
    rc=$?
    assert_rc "不正なSTATUS形式は失敗" 1 $rc
}

# =============================================================================
# テスト: should_retry
# =============================================================================
test_should_retry_complete_code_match() {
    load_test_config
    should_retry "0250" "0000" 2>/dev/null
    assert_rc "完了コードがリトライ対象" 0 $?
}

test_should_retry_detail_code_match() {
    load_test_config
    should_retry "0000" "0301" 2>/dev/null
    assert_rc "詳細コードがリトライ対象" 0 $?
}

test_should_retry_no_match() {
    load_test_config
    should_retry "0000" "0000" 2>/dev/null
    assert_rc "正常コードはリトライ不要" 1 $?
}

test_should_retry_unknown_code() {
    load_test_config
    should_retry "9999" "9999" 2>/dev/null
    assert_rc "未定義コードはリトライ不要" 1 $?
}

# =============================================================================
# テスト: invoke_utlsend（スタブ経由）
# =============================================================================
test_invoke_utlsend_sync_mode() {
    reset_stubs
    STUB_UTLSEND_RC=0

    invoke_utlsend "HULFTID01" "/tmp/test.dat" 1 300 2>/dev/null
    assert_rc "invoke_utlsend 同期 正常終了" 0 $?
    assert_eq "utlsend 呼び出し回数" 1 $STUB_UTLSEND_CALL_COUNT
}

test_invoke_utlsend_async_mode() {
    reset_stubs
    STUB_UTLSEND_RC=0

    invoke_utlsend "HULFTID01" "/tmp/test.dat" 0 300 2>/dev/null
    assert_rc "invoke_utlsend 非同期 正常終了" 0 $?
    assert_eq "utlsend 呼び出し回数" 1 $STUB_UTLSEND_CALL_COUNT
}

test_invoke_utlsend_failure() {
    reset_stubs
    STUB_UTLSEND_RC=8

    invoke_utlsend "HULFTID01" "/tmp/test.dat" 1 300 2>/dev/null
    assert_rc "invoke_utlsend 失敗コード伝播" 8 $?
}

# =============================================================================
# テスト: run_send_with_retry（シナリオテスト）
# =============================================================================
test_run_send_with_retry_success_first_try() {
    load_test_config
    reset_stubs
    STUB_UTLSEND_RC=0
    STUB_UTLLIST_OUTPUT="FILEID  HOST  2024/01/01  10:00:00  10:00:01  100 0000-0000  LAN"

    run_send_with_retry "HID" "/tmp/f.dat" 1 300 2>/dev/null
    assert_rc "初回で成功" 0 $?
    assert_eq "utlsend 呼び出し回数 (リトライなし)" 1 $STUB_UTLSEND_CALL_COUNT
    assert_eq "sleep 呼び出し回数 (なし)" 0 $STUB_SLEEP_CALL_COUNT
}

test_run_send_with_retry_retry_then_success() {
    load_test_config
    reset_stubs

    # 1回目: リトライ対象コード、2回目: 正常コード
    local call_count=0
    run_utllist() {
        call_count=$(( call_count + 1 ))
        if [[ $call_count -eq 1 ]]; then
            echo "FILEID  HOST  2024/01/01  10:00:00  10:00:01  100 0250-0301  LAN"
        else
            echo "FILEID  HOST  2024/01/01  10:01:00  10:01:01  100 0000-0000  LAN"
        fi
        return 0
    }

    run_send_with_retry "HID" "/tmp/f.dat" 1 300 2>/dev/null
    assert_rc "リトライ後に成功" 0 $?
    assert_eq "utlsend 呼び出し回数 (1リトライ)" 2 $STUB_UTLSEND_CALL_COUNT
    assert_eq "sleep 呼び出し回数 (1回)" 1 $STUB_SLEEP_CALL_COUNT

    # スタブを元に戻す
    run_utllist() {
        echo "${STUB_UTLLIST_OUTPUT}"
        return "${STUB_UTLLIST_RC:-0}"
    }
}

test_run_send_with_retry_exhausted() {
    load_test_config
    reset_stubs
    # 常にリトライ対象コードを返す
    STUB_UTLLIST_OUTPUT="FILEID  HOST  2024/01/01  10:00:00  10:00:01  100 0250-0301  LAN"

    run_send_with_retry "HID" "/tmp/f.dat" 1 300 2>/dev/null
    local rc=$?
    assert_rc "リトライ上限超過でエラー" $EXIT_ERR_RETRY_OVER $rc
    # RETRY_COUNT=2 なので初回+2回=3回呼ばれる
    assert_eq "utlsend 呼び出し回数 (上限まで)" 3 $STUB_UTLSEND_CALL_COUNT
}

test_run_send_with_retry_utlsend_failure() {
    load_test_config
    reset_stubs
    STUB_UTLSEND_RC=8

    run_send_with_retry "HID" "/tmp/f.dat" 1 300 2>/dev/null
    assert_rc "utlsend 失敗は即終了" $EXIT_ERR_UTLSEND $?
    assert_eq "utlsend は1回だけ呼ばれる" 1 $STUB_UTLSEND_CALL_COUNT
}

test_run_send_with_retry_async_no_status_check() {
    load_test_config
    reset_stubs
    STUB_UTLSEND_RC=0
    STUB_UTLLIST_RC=1  # utllist が失敗する設定（呼ばれないはず）

    run_send_with_retry "HID" "/tmp/f.dat" 0 300 2>/dev/null
    assert_rc "非同期モードは成功" 0 $?
    # 非同期なのでutllistは呼ばれない → UTLLIST スタブのカウントは変化なし
}

test_run_send_with_retry_utllist_failure() {
    load_test_config
    reset_stubs
    STUB_UTLSEND_RC=0
    STUB_UTLLIST_RC=1  # utllist 失敗

    run_send_with_retry "HID" "/tmp/f.dat" 1 300 2>/dev/null
    assert_rc "utllist 失敗はエラー" $EXIT_ERR_UTLLIST $?
}

# =============================================================================
# テスト実行
# =============================================================================
echo "============================================="
echo "hulft_send.sh 単体テスト"
echo "============================================="
echo ""

echo "--- validate_params ---"
run_test test_validate_params_all_valid
run_test test_validate_params_missing_system_id
run_test test_validate_params_missing_hulft_id
run_test test_validate_params_missing_file
run_test test_validate_params_file_not_exist
run_test test_validate_params_invalid_timeout
run_test test_validate_params_timeout_empty_is_ok

echo "--- parse_params ---"
run_test test_parse_params_all_options
run_test test_parse_params_async
run_test test_parse_params_default_sync
run_test test_parse_params_unknown_option

echo "--- apply_defaults ---"
run_test test_apply_defaults_sets_timeout_when_empty
run_test test_apply_defaults_keeps_existing_timeout

echo "--- parse_utllist_output ---"
run_test test_parse_utllist_normal
run_test test_parse_utllist_picks_last_line
run_test test_parse_utllist_retry_target_code
run_test test_parse_utllist_empty_input
run_test test_parse_utllist_invalid_status_format

echo "--- should_retry ---"
run_test test_should_retry_complete_code_match
run_test test_should_retry_detail_code_match
run_test test_should_retry_no_match
run_test test_should_retry_unknown_code

echo "--- invoke_utlsend ---"
run_test test_invoke_utlsend_sync_mode
run_test test_invoke_utlsend_async_mode
run_test test_invoke_utlsend_failure

echo "--- run_send_with_retry (シナリオ) ---"
run_test test_run_send_with_retry_success_first_try
run_test test_run_send_with_retry_retry_then_success
run_test test_run_send_with_retry_exhausted
run_test test_run_send_with_retry_utlsend_failure
run_test test_run_send_with_retry_async_no_status_check
run_test test_run_send_with_retry_utllist_failure

echo ""
print_summary

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1

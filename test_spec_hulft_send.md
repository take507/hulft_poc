# テスト仕様書：hulft_send.sh 単体テスト

**対象スクリプト:** `hulft_send.sh`  
**テストスクリプト:** `test_hulft_send.sh`  
**テスト種別:** 単体テスト（関数レベル）  
**作成日:** 2026-05-29

---

## 1. テスト概要

### 1.1 目的

`hulft_send.sh` が提供する各関数の正常系・異常系の動作を、外部コマンドに依存せず独立して検証する。

### 1.2 テスト方針

| 項目 | 内容 |
|------|------|
| テスト手法 | `hulft_send.sh` を `source` で読み込み、関数単位でテスト |
| 外部コマンド | `utlsend` / `utllist` / `sleep` をスタブ関数で差し替え |
| 設定ファイル | テスト用インメモリ変数（`load_test_config`）で代用 |
| テスト間分離 | `setUp` / `tearDown` パターン（`reset_stubs` / `load_test_config`）を採用 |

### 1.3 テスト設定値（`load_test_config`）

| 設定項目 | 値 | 備考 |
|----------|----|------|
| `DEFAULT_TIMEOUT` | 300 | デフォルトタイムアウト（秒） |
| `RETRY_COUNT` | 2 | 最大リトライ回数 |
| `RETRY_INTERVAL` | 0 | テスト高速化のため0秒 |
| `RETRY_COMPLETE_CODES` | `0250 0251` | 完了コードのリトライ対象 |
| `RETRY_DETAIL_CODES` | `0301 0302` | 詳細コードのリトライ対象 |

### 1.4 スタブ仕様

| スタブ関数 | 制御変数 | 動作 |
|------------|----------|------|
| `run_utlsend` | `STUB_UTLSEND_RC`、`STUB_UTLSEND_CALL_COUNT` | 呼び出し回数をカウントし、指定した終了コードを返す |
| `run_utllist` | `STUB_UTLLIST_OUTPUT`、`STUB_UTLLIST_RC` | 指定した文字列を stdout に出力し、指定した終了コードを返す |
| `run_sleep` | `STUB_SLEEP_CALL_COUNT` | 実際のスリープは行わず、呼び出し回数のみカウント |

---

## 2. テストケース一覧

### 2.1 `validate_params`（引数バリデーション）

| No. | テスト関数 | テストケース名 | 入力条件 | 期待する終了コード |
|-----|-----------|--------------|----------|------------------|
| V-01 | `test_validate_params_all_valid` | 全パラメータ正常 | システムID・HULFTID・既存ファイル・数値タイムアウト | `0` |
| V-02 | `test_validate_params_missing_system_id` | システムID未指定 | システムID が空文字 | `1` |
| V-03 | `test_validate_params_missing_hulft_id` | HULFTID未指定 | HULFTID が空文字 | `1` |
| V-04 | `test_validate_params_missing_file` | ファイルパス未指定 | ファイルパスが空文字 | `1` |
| V-05 | `test_validate_params_file_not_exist` | 存在しないファイル | `/nonexistent/file.dat` を指定 | `1` |
| V-06 | `test_validate_params_invalid_timeout` | タイムアウトが数値以外 | タイムアウトに `"abc"` を指定 | `1` |
| V-07 | `test_validate_params_timeout_empty_is_ok` | タイムアウト省略（空文字） | タイムアウトに `""` を指定 | `0` |

---

### 2.2 `parse_params`（コマンドライン引数パース）

| No. | テスト関数 | テストケース名 | 入力条件 | 期待結果 |
|-----|-----------|--------------|----------|---------|
| P-01 | `test_parse_params_all_options` | 全オプション指定 | `-s SYS01 -f HULFTID01 --file /tmp/test.dat --sync -w 120` | 終了コード `0`、各変数に正しい値がセット |
| P-02 | `test_parse_params_async` | 非同期フラグ指定 | `--async` オプション | `PARAM_SYNC=0` |
| P-03 | `test_parse_params_default_sync` | デフォルトは同期 | `--sync` / `--async` 未指定 | `PARAM_SYNC=1` |
| P-04 | `test_parse_params_unknown_option` | 不明なオプション | `--unknown-opt` を指定 | 終了コード `1` |

**P-01 変数検証詳細：**

| 変数 | 期待値 |
|------|--------|
| `PARAM_SYSTEM_ID` | `SYS01` |
| `PARAM_HULFT_ID` | `HULFTID01` |
| `PARAM_FILE_PATH` | `/tmp/test.dat` |
| `PARAM_SYNC` | `1` |
| `PARAM_TIMEOUT` | `120` |

---

### 2.3 `apply_defaults`（デフォルト値適用）

| No. | テスト関数 | テストケース名 | 入力条件 | 期待結果 |
|-----|-----------|--------------|----------|---------|
| D-01 | `test_apply_defaults_sets_timeout_when_empty` | タイムアウト未設定時にデフォルト値を適用 | `timeout=""` | `timeout=300`（`DEFAULT_TIMEOUT` の値） |
| D-02 | `test_apply_defaults_keeps_existing_timeout` | タイムアウト設定済みの場合は変更しない | `timeout="120"` | `timeout=120`（変更なし） |

---

### 2.4 `parse_utllist_output`（utllist 出力解析）

| No. | テスト関数 | テストケース名 | 入力条件 | 期待する stdout / 終了コード |
|-----|-----------|--------------|----------|-----------------------------|
| U-01 | `test_parse_utllist_normal` | 正常ステータスの解析 | 複数行、最終行に `0000-0000` | 出力: `"0000 0000"`、終了コード `0` |
| U-02 | `test_parse_utllist_picks_last_line` | 最終行のSTATUSを取得 | 複数行、最終行に `0000-0000` | 出力: `"0000 0000"` |
| U-03 | `test_parse_utllist_retry_target_code` | リトライ対象コードの解析 | 最終行に `0250-0301` | 出力: `"0250 0301"`、終了コード `0` |
| U-04 | `test_parse_utllist_empty_input` | 空入力 | 空文字列を渡す | 終了コード `1` |
| U-05 | `test_parse_utllist_invalid_status_format` | 不正なSTATUS形式 | STATUS 列が `INVALID` | 終了コード `1` |

---

### 2.5 `should_retry`（リトライ判定）

| No. | テスト関数 | テストケース名 | 入力条件（完了コード / 詳細コード） | 期待する終了コード |
|-----|-----------|--------------|----------------------------------|------------------|
| R-01 | `test_should_retry_complete_code_match` | 完了コードがリトライ対象 | `0250` / `0000` | `0`（リトライすべき） |
| R-02 | `test_should_retry_detail_code_match` | 詳細コードがリトライ対象 | `0000` / `0301` | `0`（リトライすべき） |
| R-03 | `test_should_retry_no_match` | 正常コードはリトライ不要 | `0000` / `0000` | `1`（リトライ不要） |
| R-04 | `test_should_retry_unknown_code` | 未定義コードはリトライ不要 | `9999` / `9999` | `1`（リトライ不要） |

---

### 2.6 `invoke_utlsend`（utlsend 呼び出し）

| No. | テスト関数 | テストケース名 | スタブ設定 | 期待する終了コード / 呼び出し回数 |
|-----|-----------|--------------|-----------|--------------------------------|
| I-01 | `test_invoke_utlsend_sync_mode` | 同期モードで正常終了 | `STUB_UTLSEND_RC=0` | 終了コード `0`、呼び出し回数 `1` |
| I-02 | `test_invoke_utlsend_async_mode` | 非同期モードで正常終了 | `STUB_UTLSEND_RC=0` | 終了コード `0`、呼び出し回数 `1` |
| I-03 | `test_invoke_utlsend_failure` | utlsend が失敗した場合 | `STUB_UTLSEND_RC=8` | 終了コード `8`（失敗コードを伝播） |

---

### 2.7 `run_send_with_retry`（リトライ付き送信シナリオ）

| No. | テスト関数 | テストケース名 | スタブ設定 | 期待する終了コード / 検証項目 |
|-----|-----------|--------------|-----------|------------------------------|
| S-01 | `test_run_send_with_retry_success_first_try` | 初回で成功 | `UTLSEND_RC=0`、utllist が `0000-0000` を返す | 終了コード `0`、utlsend 呼び出し `1`回、sleep `0`回 |
| S-02 | `test_run_send_with_retry_retry_then_success` | 1回リトライ後に成功 | 1回目 utllist: `0250-0301`、2回目: `0000-0000` | 終了コード `0`、utlsend 呼び出し `2`回、sleep `1`回 |
| S-03 | `test_run_send_with_retry_exhausted` | リトライ上限超過 | utllist が常に `0250-0301` を返す | 終了コード `EXIT_ERR_RETRY_OVER`、utlsend 呼び出し `3`回（初回＋リトライ2回） |
| S-04 | `test_run_send_with_retry_utlsend_failure` | utlsend 失敗で即時終了 | `UTLSEND_RC=8` | 終了コード `EXIT_ERR_UTLSEND`、utlsend 呼び出し `1`回 |
| S-05 | `test_run_send_with_retry_async_no_status_check` | 非同期モードではステータス確認なし | `UTLSEND_RC=0`、`UTLLIST_RC=1`（呼ばれないはず） | 終了コード `0` |
| S-06 | `test_run_send_with_retry_utllist_failure` | utllist 失敗でエラー | `UTLSEND_RC=0`、`UTLLIST_RC=1` | 終了コード `EXIT_ERR_UTLLIST` |

---

## 3. テストフレームワーク仕様

### 3.1 アサーション関数

| 関数 | シグネチャ | 説明 |
|------|-----------|------|
| `assert_eq` | `(label, expected, actual)` | 文字列の一致を検証。不一致の場合は期待値・実際の値を表示 |
| `assert_rc` | `(label, expected_rc, actual_rc)` | 終了コードの一致を検証（`assert_eq` のラッパー） |

### 3.2 テスト実行関数

| 関数 | シグネチャ | 説明 |
|------|-----------|------|
| `run_test` | `(test_name)` | テスト関数を実行し、テスト名をヘッダとして表示 |
| `print_summary` | `()` | 全テスト実行後に合計・成功・失敗件数とNG一覧を表示 |

### 3.3 テスト結果の見方

```
[PASS] テストケース名
[FAIL] テストケース名
       expected: '期待値'
       actual:   '実際の値'
```

### 3.4 最終終了コード

| 条件 | 終了コード |
|------|-----------|
| 全テスト成功 | `0` |
| 1件以上失敗 | `1` |

---

## 4. テスト実行方法

```bash
# テストスクリプトと hulft_send.sh を同一ディレクトリに配置して実行
bash test_hulft_send.sh
```

**前提条件：**
- `hulft_send.sh` が `test_hulft_send.sh` と同一ディレクトリに存在すること
- Bash 4.0 以上（`set -uo pipefail`、連想配列等を使用）

---

## 5. テストケース総数

| テスト対象関数 | テスト件数 |
|--------------|-----------|
| `validate_params` | 7 |
| `parse_params` | 4 |
| `apply_defaults` | 2 |
| `parse_utllist_output` | 5 |
| `should_retry` | 4 |
| `invoke_utlsend` | 3 |
| `run_send_with_retry` | 6 |
| **合計** | **31** |

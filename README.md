# log-split-tool

試験実施時にサービスの既存ログへマーカーを出力し、試験後にそのマーカーをもとに試験単位でエビデンスログを切り分けるツールです。

## 概要

常時稼働しているアプリケーションや MQTT ブローカー、API サービスなどのログは継続的に追記されるため、試験ごとにログファイルを分離することが難しい場合があります。本ツールは、試験開始・終了時にログへマーカーを埋め込み、後から試験単位のエビデンスファイルを自動生成します。

複数のログファイルを同時対象にできるため、アプリログ・MQTTログ・APIログをまとめて1回の操作でエビデンス取得できます。

```
[試験担当者]
    |
    | 1. run_test_with_marker.sh を実行
    v
[app.log]   ... [TEST_MARKER_START] test_id=TEST_... ...
                (アプリが出力するログ)
                [TEST_MARKER_END]   test_id=TEST_... ...

[mqtt.log]  ... [TEST_MARKER_START] test_id=TEST_... ...
                (MQTT ブローカーのログ)
                [TEST_MARKER_END]   test_id=TEST_... ...
    |
    | 2. extract_evidence.sh を実行
    v
[evidence/]
    └── evidence_TEST_20260526_..._API/
        ├── app.log
        └── mqtt.log
```

## ディレクトリ構成

```
log-split-tool/
├── run_test_with_marker.sh       # プログラム1: マーカー出力付き試験実行
├── extract_evidence.sh           # プログラム2: エビデンス自動抽出
├── config/
│   └── settings.env              # 設定ファイル
├── markers/                      # 試験識別子管理ファイル出力先 (実行時に生成)
│   └── test_markers.csv
└── evidence/                     # エビデンスファイル出力先 (実行時に生成)
    ├── evidence_<TEST_ID>/
    │   ├── app.log
    │   └── mqtt.log
    └── summary.txt
```

> `markers/` と `evidence/` はスクリプト初回実行時に自動作成されます。

## 動作環境

- Linux (systemd 環境含む)
- Bash 4.0 以上
- `logger` コマンド (syslog / journald モード使用時)
- `awk`, `sed`, `grep` (標準コマンド)

## セットアップ

```bash
git clone https://github.com/miya-taro/log-split-tool.git
cd log-split-tool
chmod +x run_test_with_marker.sh extract_evidence.sh
```

`config/settings.env` を環境に合わせて編集します。

```bash
vi config/settings.env
```

## 基本的な使い方（2ステップ）

### ステップ1: 設定ファイルにログファイルを列挙する

```bash
# config/settings.env
LOG_TYPE=file
LOG_FILES=(
  "/var/log/app.log"
  "/var/log/mqtt.log"
  "/var/log/api.log"
)
```

### ステップ2: 試験実行 → エビデンス抽出

```bash
# 試験実行（全ファイルに同時にマーカーが書き込まれる）
./run_test_with_marker.sh -n "API疎通試験"

# エビデンス抽出（全ファイルから自動抽出）
./extract_evidence.sh -m markers/test_markers.csv
```

---

## 詳細

### run_test_with_marker.sh

```bash
./run_test_with_marker.sh -n <試験名> [オプション] [-- コマンド]
```

| オプション | 説明 | デフォルト |
|---|---|---|
| `-n`, `--name` | 試験名称（必須） | — |
| `-t`, `--tester` | 実施者名 | OS ユーザー名 |
| `-l`, `--log-type` | ログ種別: `syslog` \| `journald` \| `file` \| `stdout` | `syslog` |
| `-m`, `--markers` | 識別子管理ファイルパス | `markers/test_markers.csv` |

**コマンドあり（自動実行）**

```bash
# コマンドの成否が試験結果（OK/NG）に反映される
./run_test_with_marker.sh -n "API疎通試験" -- curl -s http://localhost:8080/health

# 複数コマンドは && か ; で連結
./run_test_with_marker.sh -n "複合試験" -- "cmd1 && cmd2"

# シェルスクリプトを渡すことも可能
./run_test_with_marker.sh -n "MQTT接続確認" -t yamada -- ./scenario_mqtt.sh
```

**コマンドなし（手動操作モード）**

```bash
./run_test_with_marker.sh -n "手動疎通確認"
```

```
試験を実施してください。
  完了 → Enter
  失敗 → f + Enter
  中断 → Ctrl+C
```

### extract_evidence.sh

```bash
./extract_evidence.sh -m <管理ファイル> [オプション]
```

| オプション | 説明 | デフォルト |
|---|---|---|
| `-m`, `--markers` | 識別子管理ファイルパス（必須） | — |
| `-l`, `--log` | 対象ログファイルパス（`LOG_FILES` より優先） | — |
| `-j`, `--journalctl` | journalctl から取得 | — |
| `-o`, `--output` | エビデンス出力先ディレクトリ | `evidence/` |
| `-e`, `--mode` | 抽出モード: `strict` \| `loose` | `strict` |
| `-i`, `--id` | 特定の試験 ID のみ抽出 | 全件 |

**ログソースの優先順位:** `--journalctl` > `-l` > `config/settings.env の LOG_FILES`

**抽出モード**

| モード | 終了マーカーがない場合の動作 |
|---|---|
| `strict`（デフォルト）| 次のマーカー直前まで抽出 |
| `loose` | 開始マーカーから `FALLBACK_LINES`（デフォルト 500）行を抽出 |

### 出力ファイル構成

**複数ファイル時（LOG_FILES 使用）**

```
evidence/
├── evidence_TEST_20260526_..._API/   # 試験 ID ごとのサブディレクトリ
│   ├── app.log
│   └── mqtt.log
└── summary.txt
```

**単一ファイル時（-l 指定）**

```
evidence/
├── evidence_TEST_20260526_..._API.log
└── summary.txt
```

**summary.txt の例**

```
========================================
  エビデンス抽出サマリ
  実行日時: 2026-05-26T22:57:09
  ログソース:
    - app.log
    - mqtt.log
========================================

  TEST_20260526_225553_435_API (API疎通試験)
    [OK]         app.log                        -> app.log
    [OK]         mqtt.log                       -> mqtt.log

  TEST_20260526_999999_99_ABORT (ABORT試験)
    [INCOMPLETE] app.log                        -> app.log ※終了マーカーなし

----------------------------------------
  合計   : 2
  成功   : 1
  不完全 : 1
  失敗   : 0
----------------------------------------
```

## 設定ファイル（config/settings.env）

```bash
# ログ種別: syslog | journald | file | stdout
LOG_TYPE=file

# マーカーを書き込む対象ログファイル（複数指定可）
LOG_FILES=(
  "/var/log/app.log"
  "/var/log/mqtt.log"
)

# 抽出モード: strict | loose
EXTRACT_MODE=strict

# 終了マーカーなし時のフォールバック行数
FALLBACK_LINES=500
```

すべての設定は環境変数でも上書き可能です（優先順位: 環境変数 > settings.env > デフォルト値）。

## 試験識別子の形式

```
TEST_YYYYMMDD_HHMMSS_PID_SLUG
例: TEST_20260526_225553_435_API
```

## 管理ファイル（test_markers.csv）の形式

| 列 | 内容 |
|---|---|
| `test_id` | 試験識別子 |
| `test_name` | 試験名称 |
| `tester` | 実施者 |
| `start_time` | 試験開始時刻 |
| `end_time` | 試験終了時刻 |
| `status` | 実行結果 (`OK` / `NG` / `ABORT`) |
| `evidence_file` | 抽出後の出力先 |

## 異常終了時の動作

スクリプトが途中で強制終了（Ctrl+C、エラー等）した場合、`trap` により `ABORT` マーカーと失敗時刻が自動記録されます。エビデンス抽出時はサマリに `[INCOMPLETE]` として出力されます。

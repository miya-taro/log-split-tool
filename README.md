# log-split-tool

試験実施時にサービスの既存ログへマーカーを出力し、試験後にそのマーカーをもとに試験単位でエビデンスログを切り分けるツールです。

## 概要

常時稼働しているアプリケーションや MQTT ブローカー、API サービスなどのログは継続的に追記されるため、試験ごとにログファイルを分離することが難しい場合があります。本ツールは、試験開始・終了時にログへマーカーを埋め込み、後から試験単位のエビデンスファイルを自動生成します。

```
[試験担当者]
    |
    | 1. run_test_with_marker.sh を実行
    v
[ログ]  ... [TEST_MARKER_START] test_id=TEST_20260526_... ...
            (試験対象の操作・コマンド)
            [TEST_MARKER_END]   test_id=TEST_20260526_... ...
    |
    | 2. extract_evidence.sh を実行
    v
[evidence/]
    ├── evidence_TEST_20260526_..._API.log
    ├── evidence_TEST_20260526_..._DB.log
    └── summary.txt
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
    ├── evidence_<TEST_ID>.log
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

設定ファイルを環境に合わせて編集します。

```bash
vi config/settings.env
```

## 使い方

### 1. 試験の実行（マーカー出力）

```bash
./run_test_with_marker.sh -n <試験名> [オプション] [-- コマンド]
```

| オプション | 説明 | デフォルト |
|---|---|---|
| `-n`, `--name` | 試験名称（必須） | — |
| `-t`, `--tester` | 実施者名 | OS ユーザー名 |
| `-l`, `--log-type` | ログ種別: `syslog` \| `journald` \| `file` \| `stdout` | `syslog` |
| `-f`, `--log-file` | `file` モード時の出力先パス | `/tmp/test_marker.log` |
| `-m`, `--markers` | 識別子管理ファイルパス | `markers/test_markers.csv` |

**実行例**

```bash
# API の疎通確認（syslog に記録）
./run_test_with_marker.sh -n "API疎通試験" -- curl -s http://localhost:8080/health

# ファイルにマーカーを書く場合
./run_test_with_marker.sh -n "MQTT接続確認" -t yamada -l file -f /var/log/myapp/app.log -- ./scenario_mqtt.sh

# 複数コマンドは && か ; で連結
./run_test_with_marker.sh -n "複合試験" -- "cmd1 && cmd2"
```

実行後、試験識別子と次のステップが表示されます。

```
========================================
 試験終了
  試験ID   : TEST_20260526_225553_435_API
  終了時刻 : 2026-05-26T22:55:53
  結果     : OK
========================================

次のステップ:
  エビデンス抽出: ./extract_evidence.sh -m markers/test_markers.csv -l <ログファイルパス>
  試験ID         : TEST_20260526_225553_435_API
```

### 2. エビデンスの抽出

```bash
./extract_evidence.sh -m <管理ファイル> -l <ログファイル> [オプション]
```

| オプション | 説明 | デフォルト |
|---|---|---|
| `-m`, `--markers` | 識別子管理ファイルパス（必須） | — |
| `-l`, `--log` | 対象ログファイルパス | — |
| `-j`, `--journalctl` | journalctl から取得（`-l` の代わりに使用） | — |
| `-o`, `--output` | エビデンス出力先ディレクトリ | `evidence/` |
| `-e`, `--mode` | 抽出モード: `strict` \| `loose` | `strict` |
| `-i`, `--id` | 特定の試験 ID のみ抽出 | 全件 |

**実行例**

```bash
# syslog から全試験を抽出
./extract_evidence.sh -m markers/test_markers.csv -l /var/log/syslog -o evidence/

# journalctl から抽出
./extract_evidence.sh -m markers/test_markers.csv --journalctl -o evidence/

# 特定 ID のみ抽出
./extract_evidence.sh -m markers/test_markers.csv -l /var/log/syslog \
  -i TEST_20260526_225553_435_API
```

**抽出モード**

| モード | 終了マーカーがない場合の動作 |
|---|---|
| `strict`（デフォルト）| 次のマーカー直前まで抽出 |
| `loose` | 開始マーカーから `FALLBACK_LINES`（デフォルト 500）行を抽出 |

### 3. 結果の確認

```
evidence/
├── evidence_TEST_20260526_225553_435_API.log   # 試験別エビデンス
├── evidence_TEST_20260526_225553_456_DB.log
└── summary.txt                                 # 抽出結果サマリ
```

`summary.txt` の例:

```
========================================
  エビデンス抽出サマリ
  実行日時: 2026-05-26T22:57:09
  ログソース: /var/log/syslog
========================================

[OK]          TEST_20260526_225553_435_API          -> evidence_TEST_20260526_225553_435_API.log
[OK]          TEST_20260526_225553_456_DB            -> evidence_TEST_20260526_225553_456_DB.log
[INCOMPLETE]  TEST_20260526_999999_99_ABORT          -> evidence_TEST_..._ABORT.log ※終了マーカーなし

----------------------------------------
  合計   : 3
  成功   : 2
  不完全 : 1
  失敗   : 0
----------------------------------------
```

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

## 設定ファイル（config/settings.env）

```bash
LOG_TYPE=syslog          # syslog | journald | file | stdout
# LOG_FILE=/var/log/myapp/app.log   # LOG_TYPE=file 時に使用
EXTRACT_MODE=strict      # strict | loose
FALLBACK_LINES=500       # 終了マーカーなし時のフォールバック行数
```

すべての設定は環境変数でも上書き可能です。

```bash
LOG_TYPE=file LOG_FILE=/tmp/test.log ./run_test_with_marker.sh -n "試験名"
```

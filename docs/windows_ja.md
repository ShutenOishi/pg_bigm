# pg_bigm Windows x64 バイナリ利用ガイド

この文書は、[pg_bigm公式ドキュメント](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md)の内容を前提として、このリポジトリが配布する **非公式Windows x64バイナリ**の導入に必要なWindows固有の手順を補足するものです。

pg_bigmの機能仕様、SQL API、設定パラメータ、全文検索や類似度検索の使い方、制限事項については公式ドキュメントを正規の情報源としてください。

## 概要

pg_bigm（ピージーバイグラム）は、PostgreSQL上で全文検索機能を提供するモジュールです。2-gram（バイグラム）方式で全文検索用のインデックスを作成し、GINインデックスを利用して高速な文字列検索を行えます。

このリポジトリでは、公式pg_bigmソースをWindows向けにビルドした `pg_bigm.dll` と、公式ソースに含まれる拡張定義・SQL・ドキュメントをPostgreSQLメジャーバージョンごとのZIPとして配布します。

## 対応環境

- OS: Windows x64
- pg_bigm: 1.2
- 使用する公式ソース: `v1.2-20250903`
- PostgreSQL: このリポジトリの [README_ja.md](../README_ja.md#対応postgresqlバージョン) に記載したメンテナンス対象バージョン

**PostgreSQLのメジャーバージョンが異なるZIPを使用しないでください。**

例えば、PostgreSQL 18には `-pg18-windows-x64.zip` を使用します。

## ダウンロード

[GitHub Releases](https://github.com/ShutenOishi/pg_bigm/releases) から対象ZIPをダウンロードします。

例:

~~~text
pg_bigm-v1.2-20250903-pg18-windows-x64.zip
~~~

必要に応じて、同じReleaseに添付されている `SHA256SUMS.txt` でファイルのSHA-256を確認してください。

PowerShellで確認する場合:

~~~powershell
Get-FileHash .\pg_bigm-v1.2-20250903-pg18-windows-x64.zip -Algorithm SHA256
~~~

## インストール

### 1. PostgreSQLを停止

既存の `pg_bigm.dll` を更新する場合を含め、DLLを置き換える前にPostgreSQLを停止します。

WindowsサービスとしてPostgreSQLを実行している場合は、サービス管理画面や管理用コマンドなど、現在の運用方法に従って安全に停止してください。

### 2. ZIPを展開

使用しているPostgreSQLのメジャーバージョンに一致するZIPを展開します。

主な内容:

~~~text
lib/
  pg_bigm.dll
share/
  extension/
    pg_bigm.control
    pg_bigm--*.sql
LICENSE
UPSTREAM-README.md
docs/
  pg_bigm.md
  pg_bigm_en.md
PACKAGE-INFO.txt
~~~

### 3. ファイルを配置

展開したファイルをPostgreSQLのインストール先へコピーします。

~~~text
ZIPの lib\pg_bigm.dll
  -> <PostgreSQL>\lib\pg_bigm.dll

ZIPの share\extension\pg_bigm.control
ZIPの share\extension\pg_bigm--*.sql
  -> <PostgreSQL>\share\extension\
~~~

一般的なEnterpriseDB版PostgreSQLのインストール先では、次のようなディレクトリ構成になります。

~~~text
C:\Program Files\PostgreSQL\18\lib
C:\Program Files\PostgreSQL\18\share\extension
~~~

実際のインストール先が異なる場合は、その環境のPostgreSQLディレクトリを使用してください。

## pg_bigmの登録

公式ドキュメントと同様に、pg_bigmの共有ライブラリをPostgreSQLへプリロードします。

`postgresql.conf` の例:

~~~conf
shared_preload_libraries = 'pg_bigm'
~~~

既に他の共有ライブラリを指定している場合は、既存設定を消さず、PostgreSQLの設定形式に従って `pg_bigm` を追加してください。

公式pg_bigmドキュメントでは、`shared_preload_libraries` または用途に応じて `session_preload_libraries` に `pg_bigm` を設定する必要があるとされています。

`shared_preload_libraries` を変更した場合はPostgreSQLを再起動します。

次に、pg_bigmを使用するデータベースへ接続して拡張を登録します。

~~~sql
CREATE EXTENSION pg_bigm;
~~~

psqlで登録状況を確認する場合:

~~~text
\dx pg_bigm
~~~

`CREATE EXTENSION` はデータベース単位で実行するため、pg_bigmを使用する各データベースで登録してください。

## 基本的な動作確認

公式ドキュメントの説明に沿って、GINインデックスの演算子クラス `gin_bigm_ops` を使用できます。

例:

~~~sql
CREATE TABLE pg_bigm_windows_test (value text);

INSERT INTO pg_bigm_windows_test VALUES
  ('PostgreSQLで全文検索'),
  ('Windowsでpg_bigmを利用');

CREATE INDEX pg_bigm_windows_test_idx
  ON pg_bigm_windows_test
  USING gin (value gin_bigm_ops);

SELECT *
FROM pg_bigm_windows_test
WHERE value LIKE likequery('全文検索');
~~~

確認後:

~~~sql
DROP TABLE pg_bigm_windows_test;
~~~

全文検索機能、類似度検索、`likequery`、`bigm_similarity` などの詳細は公式日本語ドキュメントを参照してください。

## 更新

### PostgreSQLのマイナー更新

同じPostgreSQLメジャーバージョン内のマイナー更新では、使用中のpg_bigmバイナリとの互換性を前提にせず、このリポジトリで対象バージョンのCI結果とRelease内容を確認してください。

このリポジトリの各Releaseは、ファイル名に記載されたPostgreSQLメジャーバージョンについて、Release作成時に設定されたマイナーバージョンでビルド・スモークテストしています。

### PostgreSQLのメジャー更新

PostgreSQL 17から18のようにメジャーバージョンを変更する場合は、移行先メジャーバージョン専用のZIPを使用してください。旧メジャーバージョン向けの `pg_bigm.dll` を流用しないでください。

### pg_bigmのバージョン更新

pg_bigm本体のバージョンを更新する場合は、公式ドキュメントのアップグレード手順と、配布ZIP内の `pg_bigm--*.sql` を確認してください。

## アンインストール

pg_bigmを登録した各データベースで、公式ドキュメントに従って拡張を削除します。

~~~sql
DROP EXTENSION pg_bigm CASCADE;
~~~

`CASCADE` はpg_bigmに依存するインデックスなどのDBオブジェクトも削除するため、実行前に影響を確認してください。

その後PostgreSQLを停止し、必要に応じて次のファイルを削除します。

~~~text
<PostgreSQL>\lib\pg_bigm.dll
<PostgreSQL>\share\extension\pg_bigm.control
<PostgreSQL>\share\extension\pg_bigm--*.sql
~~~

また、`postgresql.conf` の `shared_preload_libraries` / `session_preload_libraries` から `pg_bigm` を削除し、pg_bigm固有の設定値があれば公式ドキュメントに従って整理します。

## 公式ドキュメント

- [pg_bigm 1.2 ドキュメント（日本語）](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md)
- [pg_bigm 1.2 Documentation (English)](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm_en.md)
- [pg_bigm公式リポジトリ](https://github.com/pgbigm/pg_bigm)

この文書と公式pg_bigmドキュメントの記述に差異がある場合、pg_bigm本体の仕様については公式ドキュメントを優先してください。

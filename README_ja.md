# pg_bigm Windows バイナリ

[English](README.md) | **日本語**

このリポジトリでは、[pg_bigm](https://github.com/pgbigm/pg_bigm) の **非公式 Windows x64 バイナリ**を提供します。

pg_bigm（ピージーバイグラム）は、PostgreSQL上で全文検索機能を提供するモジュールです。2-gram（バイグラム）方式のGINインデックスを利用して、高速な文字列検索を行えます。

pg_bigm本体は pg_bigm Development Group によって開発・保守されています。pg_bigmの機能、SQLの使い方、設定、制限事項などについては、**pg_bigm公式ドキュメントを正規の情報源**としてください。

## pg_bigm公式情報

- 公式リポジトリ: https://github.com/pgbigm/pg_bigm
- このリポジトリが使用するソース: **v1.2-20250903**
- pg_bigm拡張バージョン: **1.2**
- ライセンス: PostgreSQL License（公式と同一のライセンス本文）
- 公式日本語ドキュメント: https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md
- 公式英語ドキュメント: https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm_en.md

CI/CDでは、固定した公式タグのソースをチェックアウトしてビルドします。このリポジトリには、pg_bigm本体のCソースをフォークしたコピーは保持しません。

## ドキュメント

### このリポジトリ

- [Windows x64 バイナリ利用ガイド（日本語）](docs/windows_ja.md)
- [English README](README.md)

### pg_bigm公式

- [pg_bigm 1.2 ドキュメント（日本語）](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md)
- [pg_bigm 1.2 Documentation (English)](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm_en.md)

Windows固有の配置方法や、このリポジトリで配布するZIPの構成は本リポジトリのドキュメントを参照してください。pg_bigmの機能仕様や設定値、SQL APIについては公式ドキュメントを優先してください。

## 対応PostgreSQLバージョン

Windowsバイナリは、ビルド日時点でPostgreSQLコミュニティのメンテナンス対象であるメジャーバージョンだけを対象にします。

2026-10-05時点:

| PostgreSQL | 動作確認マイナーバージョン | コミュニティEOL |
|---|---:|---:|
| 14 | 14.24 | 2026-11-12 |
| 15 | 15.19 | 2027-11-11 |
| 16 | 16.15 | 2028-11-09 |
| 17 | 17.11 | 2029-11-08 |
| 18 | 18.6 | 2030-11-14 |

PostgreSQL 14は現時点では対象ですが、設定済みEOL日を過ぎると共通pgextwin workflowのビルド対象から自動的に除外されます。PostgreSQLのライフサイクル情報は **pgextwin/build** で一元管理し、このリポジトリでは [config/extension.json](config/extension.json) にpg_bigmの対応範囲を定義します。

配布対象アーキテクチャは **Windows x64のみ**です。

## ダウンロード

このリポジトリの [Releases](https://github.com/pgextwin/pg_bigm/releases) から、使用しているPostgreSQLのメジャーバージョンに一致するZIPをダウンロードしてください。

ファイル名は次の形式です。

~~~text
pg_bigm-v1.2-20250903-pg18-windows-x64.zip
~~~

各ZIPはPostgreSQL拡張の配置に合わせて、次のファイルを含みます。

~~~text
lib/
  pg_bigm.dll
share/
  extension/
    pg_bigm.control
    pg_bigm--1.0--1.1.sql
    pg_bigm--1.1--1.2.sql
    pg_bigm--1.2.sql
LICENSE
UPSTREAM-README.md
docs/
  pg_bigm.md
  pg_bigm_en.md
PACKAGE-INFO.txt
~~~

`docs/pg_bigm.md` は、ビルドに使用した公式pg_bigmソースに含まれる日本語ドキュメントです。

## インストール

詳細は [Windows x64 バイナリ利用ガイド](docs/windows_ja.md) を参照してください。基本手順は次のとおりです。

1. 拡張バイナリを置き換える前にPostgreSQLを停止します。
2. PostgreSQLのメジャーバージョンに一致するZIPを展開します。
3. `lib/pg_bigm.dll` をPostgreSQLの `lib` ディレクトリへコピーします。
4. `share/extension/` 以下のファイルをPostgreSQLの `share/extension` ディレクトリへコピーします。
5. 公式pg_bigmドキュメントに従ってpg_bigmを設定します。特に `shared_preload_libraries`、または用途に応じて `session_preload_libraries` で `pg_bigm` をプリロードします。
6. `shared_preload_libraries` を変更した場合はPostgreSQLを再起動します。
7. pg_bigmを利用する各データベースで次を実行します。

~~~sql
CREATE EXTENSION pg_bigm;
~~~

登録確認例:

~~~text
\dx pg_bigm
~~~

pg_bigmはデータベース単位で拡張として登録されます。インストール、設定、全文検索、類似度検索、提供関数、制限事項などの詳細は、公式日本語ドキュメントを参照してください。

## CI/CD

[.github/workflows/windows.yml](.github/workflows/windows.yml) は、共通CI/CD処理を **pgextwin/build** のReusable Workflowへ委譲します。

対象となる各PostgreSQLメジャーバージョンについて、共通workflowは次を実施します。

1. **pgextwin/build** のPostgreSQLライフサイクル情報と [config/extension.json](config/extension.json) を組み合わせて対象行列を決定します。
2. EOL日を過ぎたPostgreSQLを除外します。
3. 固定した公式pg_bigmソースをチェックアウトします。
4. 対象PostgreSQLのWindows x64環境を導入します。
5. このリポジトリの **windows/ci/** 配下にあるExtension固有hookを呼び出します。
6. MSVCとCMakeで `pg_bigm.dll` をビルドします。
7. テスト用PostgreSQLへ拡張を配置します。
8. `CREATE EXTENSION pg_bigm` とGINインデックスを使った基本検索のスモークテストを行います。
9. PostgreSQLメジャーバージョンごとのZIPをGitHub Actions artifactとして作成します。

Pull Requestと `main` へのpushではCIのみを実行します。

GitHub Releaseを公開するときは、公開対象の `main` コミットから次の形式のブランチを作成します。

~~~text
release/<release-tag>
~~~

例:

~~~text
release/v1.2-20250903-windows.1
~~~

全PostgreSQLバージョンのビルドとスモークテストが成功した場合にだけRelease処理を行います。既存の同名Releaseがある場合はRelease本文を更新し、Releaseが存在しない場合はZIPと `SHA256SUMS.txt` を添付して新規作成します。

## PostgreSQL対応バージョンの更新

PostgreSQLのマイナーバージョン、Windowsパッケージ、EOL情報は **pgextwin/build** で一元管理します。

このリポジトリでは [config/extension.json](config/extension.json) にpg_bigmが許可するPostgreSQLメジャーバージョン範囲だけを定義します。pg_bigm公式側の対応状況が変わった場合はmanifestを更新し、共通CIによる全対象バージョンのビルドとスモークテストを通してからRelease対象にします。

## pg_bigmの更新

pg_bigm公式から新しいリリースが公開された場合は、次を更新します。

1. [config/extension.json](config/extension.json) の `upstream.ref` と `upstream.version`。
2. README内の公式バージョン表記とドキュメントリンク。
3. 必要に応じてWindows向け補足ドキュメント。
4. メンテナンス対象PostgreSQL全バージョンでCIを実行します。
5. 全行列が成功した場合のみ、新しいWindows Releaseを公開します。

## ライセンス

このリポジトリは、固定した公式pg_bigmソースと同じ **PostgreSQL License** を使用します。[LICENSE](LICENSE) を参照してください。

Releaseパッケージ内の `LICENSE` は、ビルド時に固定した公式pg_bigmソースから直接コピーします。

このリポジトリが配布するWindowsバイナリは非公式ビルドであり、pg_bigm Development Groupによる公式Windows配布物ではありません。

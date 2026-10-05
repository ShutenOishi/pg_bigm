# pg_bigm Windows binaries

[**日本語**](README_ja.md) | English

This repository provides **unofficial Windows x64 binaries** of [pg_bigm](https://github.com/pgbigm/pg_bigm).

pg_bigm itself is developed and maintained by the pg_bigm Development Group.
For pg_bigm features, SQL usage, configuration, limitations, and other product documentation, the **upstream pg_bigm documentation is authoritative**.

## Upstream

- Repository: https://github.com/pgbigm/pg_bigm
- Source used by this repository: **v1.2-20250903**
- pg_bigm extension version: **1.2**
- License: PostgreSQL License (same license text as upstream)

The CI/CD pipeline checks out the upstream source at the pinned tag and builds it without carrying a forked copy of the pg_bigm C sources in this repository.

## Documentation

### This repository

- [Japanese README / 日本語README](README_ja.md)
- [Windows x64 binary guide / Windows x64 バイナリ利用ガイド（日本語）](docs/windows_ja.md)

### Official pg_bigm documentation

- [Release 1.2 - 日本語](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md)
- [Release 1.2 - English](https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm_en.md)

Use this repository's documentation for Windows-specific binary placement and packaging details. For pg_bigm product behavior, SQL APIs, configuration parameters, features, and limitations, follow the official upstream documentation.

## Supported PostgreSQL versions

Windows binaries are built only for PostgreSQL major versions that are still under PostgreSQL community maintenance on the build date.

As of 2026-10-05:

| PostgreSQL | Tested minor | Community EOL |
|---|---:|---:|
| 14 | 14.24 | 2026-11-12 |
| 15 | 15.19 | 2027-11-11 |
| 16 | 16.15 | 2028-11-09 |
| 17 | 17.11 | 2029-11-08 |
| 18 | 18.6 | 2030-11-14 |

PostgreSQL 14 is therefore included today, but the shared pgextwin workflow automatically excludes entries whose configured EOL date has passed. PostgreSQL lifecycle metadata is maintained centrally in **pgextwin/build**, while this repository declares its supported range in **config/extension.json**.

Only Windows x64 is published.

## Download

Download the ZIP matching your PostgreSQL major version from this repository's **Releases** page.

Asset names follow this pattern:

~~~text
pg_bigm-v1.2-20250903-pg18-windows-x64.zip
~~~

Each ZIP contains the PostgreSQL extension layout:

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

## Installation

1. Stop PostgreSQL before replacing extension binaries.
2. Extract the ZIP for your PostgreSQL major version.
3. Copy **lib/pg_bigm.dll** to the PostgreSQL **lib** directory.
4. Copy the files under **share/extension/** to the PostgreSQL **share/extension** directory.
5. Configure pg_bigm as described by the official pg_bigm documentation. In particular, load **pg_bigm** through **shared_preload_libraries** (or **session_preload_libraries** where appropriate).
6. Restart PostgreSQL when **shared_preload_libraries** was changed.
7. In each database where pg_bigm is required, run:

~~~sql
CREATE EXTENSION pg_bigm;
~~~

For complete installation, configuration, SQL usage, and upgrade instructions, use the upstream documentation:

- Japanese: https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm.md
- English: https://github.com/pgbigm/pg_bigm/blob/REL1_2_STABLE/docs/pg_bigm_en.md

## CI/CD

**.github/workflows/windows.yml** delegates the common CI/CD mechanics to the reusable workflow in **pgextwin/build**.

For each eligible PostgreSQL major version, the shared workflow:

1. Combines centralized PostgreSQL lifecycle metadata with **config/extension.json**.
2. Excludes PostgreSQL versions whose EOL date has passed.
3. Checks out the pinned official pg_bigm source.
4. Installs the matching PostgreSQL Windows x64 distribution.
5. Calls this repository's extension-specific hooks under **windows/ci/**.
6. Builds **pg_bigm.dll** with MSVC and CMake.
7. Installs the extension into the test PostgreSQL instance.
8. Runs **CREATE EXTENSION pg_bigm** and a basic GIN/index search smoke test.
9. Packages a per-major ZIP and uploads it as a GitHub Actions artifact.

Pull requests and pushes to **main** run CI only.

To publish a GitHub Release, create a branch from the desired **main** commit named:

~~~text
release/<release-tag>
~~~

For example:

~~~text
release/v1.2-20250903-windows.1
~~~

After every matrix build and smoke test succeeds, the release job creates the matching GitHub Release and attaches all ZIP files plus **SHA256SUMS.txt**. If the matching Release already exists, the job updates its release notes instead of creating a duplicate Release. No Release operation runs if any supported PostgreSQL build fails.

## Updating PostgreSQL support

PostgreSQL minor-version, package, and EOL metadata is maintained centrally in **pgextwin/build**.

This repository controls only pg_bigm's allowed PostgreSQL range in **config/extension.json**. When pg_bigm upstream adds or removes compatibility with a major PostgreSQL version, update that manifest and let the shared CI build and smoke-test the complete resulting matrix before publishing a Release.

## Updating pg_bigm

When pg_bigm publishes a new upstream release:

1. Update **upstream.ref** and **upstream.version** in **config/extension.json**.
2. Update this README's upstream version references.
3. Run CI for all maintained PostgreSQL majors.
4. Publish a new Windows release only after the complete matrix passes.

## License

This repository uses the same PostgreSQL License text as upstream pg_bigm. See [LICENSE](LICENSE).

The release packages copy **LICENSE** directly from the pinned upstream source checkout.

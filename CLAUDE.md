# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker PG Backup is a containerized PostgreSQL backup solution that automates database backups with support for both file-based and S3-compatible storage backends. The container runs scheduled backups via cron and provides restore functionality.

## Build Commands

```bash
# Build production image (requires .env file with version variables)
./build.sh

# Build test image
./build-test.sh

# Build using docker-compose
docker compose -f docker-compose.build.yml build postgis-backup-prod
docker compose -f docker-compose.build.yml build postgis-backup-test
```

**Note:** The build scripts check for `.env` file and create it from `.example.env` if missing. Version variables:
- `POSTGRES_MAJOR_VERSION` (default: 17)
- `POSTGIS_MAJOR_VERSION` (default: 3)
- `POSTGIS_MINOR_RELEASE` (default: 5)

## Testing

```bash
# Run restore scenario tests
cd scenario_tests/restore
./test.sh

# Run S3 scenario tests
cd scenario_tests/s3
./test.sh
```

Tests automatically run scenarios as root, non-root, and with encryption enabled. Each test:
1. Starts services via docker-compose
2. Executes backup script
3. Executes restore script
4. Runs validation tests

## Architecture

### Entrypoint Flow (scripts/start.sh)

The container startup follows this sequence:

1. **Environment Configuration**: Loads all environment variables with defaults, supports `_FILE` suffixes for Docker secrets
2. **Storage Backend Selection**: Configures either `FILE` or `S3` backend
3. **Database Discovery**: Auto-discovers databases using `psql -l` if `DBLIST` not specified
4. **Cron Setup**: Generates cron configuration from template or uses mounted custom config
5. **User/Permission Setup**: Supports running as root or non-root user via `RUN_AS_ROOT`
6. **Execution Mode**: Either runs once (`RUN_ONCE=TRUE`) or starts cron daemon

### Backup Process (scripts/backups.sh + scripts/lib/)

The backup logic is split into a main orchestrator (`backups.sh`) and library modules under `scripts/lib/`:

- `db.sh`: `backup_globals()`, `backup_databases()`, `backup_single_database()`, `dump_tables()`, restore helpers
- `s3.sh`: `s3_init()`, `s3_upload()` — S3 backend configuration and uploads
- `retention.sh`: `run_retention()`, local and S3 expiry/consolidation
- `monitoring.sh`: `notify_monitoring()` — command-based, script-based, or HEALTHCHECKS_URL monitoring
- `encryption.sh`: `encrypt_stream()`, `decrypt_stream()` — OpenSSL AES-256-CBC
- `logging.sh`: `log()`, `init_logging()` — stdout or file logging with optional JSON format
- `utils.sh`: checksums, file cleanup, retry logic, metadata, dump format detection

**Backup Flow:**
1. Creates year/month directory structure: `/${S3_DEST}/${YEAR}/${MONTH}/` (where `S3_DEST` = `BUCKET/BUCKET_PATH` or just `BUCKET`)
2. Backs up global objects: `pg_dumpall --globals-only`
3. For each database in `DBLIST`:
   - Dumps full DB or individual tables based on `DB_TABLES`
   - Supports custom (-Fc) and directory (-Fd) dump formats
   - Optionally encrypts with OpenSSL AES-256-CBC
   - For S3: gzips, generates checksum/metadata, uploads via `s3_upload()`
   - For FILE: writes to local volume
4. Calls `notify_monitoring()` per-database with success/failure status
5. Runs retention cleanup if `REMOVE_BEFORE` is set

**Filename Formats:**
- Default: `/backups/${YEAR}/${MONTH}/${DUMPPREFIX}_${DB}.${DATE}.dmp`
- Fixed: `/backups/${ARCHIVE_FILENAME}.${DB}.dmp` (when `ARCHIVE_FILENAME` set)
- Table dumps: `${DUMPPREFIX}_${SCHEMA}.${TABLE}_${DATE}.sql`

### Restore Process (scripts/restore.sh)

**Two Restore Modes:**

1. **File-based** (`STORAGE_BACKEND=FILE`):
   - Requires: `TARGET_DB`, `TARGET_ARCHIVE`
   - Optional: `WITH_POSTGIS` (creates PostGIS extension)
   - Drops and recreates target database
   - Restores from specified dump file

2. **S3-based** (`STORAGE_BACKEND=S3`):
   - Takes CLI args: date (YYYY-MM-DD) and database name
   - Downloads from S3 bucket, decompresses
   - Drops/recreates database and restores

**Encryption Handling:**
Both modes check `DB_DUMP_ENCRYPTION` and decrypt using OpenSSL with `DB_DUMP_ENCRYPTION_PASS_PHRASE` if needed.

### Storage Backends

**FILE Backend:**
- Backups written to `/backups` volume mount
- Cleanup uses `find` with mtime and maintains minimum file count

**S3 Backend:**
- Uses `s3cmd` configured via `/root/.s3cfg`
- Config from `${EXTRA_CONFIG_DIR}/s3cfg` or generated from environment
- Supports custom S3-compatible endpoints (MinIO, etc.)
- Key variables: `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `HOST_BASE`, `BUCKET`

### Environment Variable System

The `file_env()` function (scripts/start.sh:4) supports Docker secrets pattern:
- Direct: `POSTGRES_PASS=mypass`
- File-based: `POSTGRES_PASS_FILE=/run/secrets/db_password`

All variables exported to `/backup-scripts/pgenv.sh` which is sourced by backup/restore scripts.

## Key Environment Variables

**Database Connection:**
- `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASS`
- `PG_CONN_PARAMETERS`: Override default connection string (default: `-h ${HOST} -p ${PORT} -U ${USER}`)
- `DBLIST`: Space-separated database names (default: auto-discover all non-template DBs)

**Backup Configuration:**
- `DUMP_ARGS`: pg_dump options (default: `-Fc` for custom format)
- `RESTORE_ARGS`: pg_restore options (default: `-j 4` for parallel restore)
- `DUMPPREFIX`: Filename prefix (default: `PG`)
- `ARCHIVE_FILENAME`: Fixed filename instead of dated
- `DB_TABLES`: Dump individual tables instead of whole DB (default: `FALSE`)

**Scheduling & Cleanup:**
- `CRON_SCHEDULE`: Cron expression (default: `0 23 * * *` = 11pm daily)
- `REMOVE_BEFORE`: Delete backups older than N days
- `MIN_SAVED_FILE`: Minimum backups to retain regardless of age (default: 0)
- `RUN_ONCE`: Run backup once and exit (useful for Kubernetes jobs)

**Monitoring:**
- `HEALTHCHECKS_URL`: Optional URL to ping on backup success, or `${HEALTHCHECKS_URL}/fail` on failure (e.g., https://hc-ping.com/your-uuid)
- `MONITORING_ENDPOINT_COMMAND`: Optional shell command to run with status arg (e.g., `my-script.sh 'success'`)

**Encryption:**
- `DB_DUMP_ENCRYPTION`: Enable AES-256-CBC encryption (default: `FALSE`)
- `DB_DUMP_ENCRYPTION_PASS_PHRASE`: Encryption passphrase (auto-generated 30-char random if not set)

**Storage:**
- `STORAGE_BACKEND`: `FILE` or `S3`
- S3-specific: `BUCKET`, `BUCKET_PATH` (sub-path within bucket), `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `HOST_BASE`, `HOST_BUCKET`, `SSL_SECURE`, `DEFAULT_REGION`

**Operational:**
- `RUN_AS_ROOT`: Run cron as root or create non-root user (default: `true`)
- `CONSOLE_LOGGING`: Log to stdout/stderr instead of `/var/log/cron.out`
- `EXTRA_CONFIG_DIR`: Mount point for custom configs (default: `/settings`)

## Docker Compose Examples

**Basic file-based backup:**
```yaml
dbbackups:
  image: kartoza/pg-backup:17-3.5
  volumes:
    - ./backups:/backups
  environment:
    - POSTGRES_HOST=db
    - POSTGRES_USER=docker
    - POSTGRES_PASS=docker
    - CRON_SCHEDULE="0 23 * * *"
```

**S3/MinIO backup:**
```yaml
dbbackups:
  image: kartoza/pg-backup:17-3.5
  environment:
    - STORAGE_BACKEND=S3
    - ACCESS_KEY_ID=minio_admin
    - SECRET_ACCESS_KEY=secure_secret
    - BUCKET=backups
    - HOST_BASE=minio:9000
    - SSL_SECURE=False
```

## Version Tagging

Images are tagged as `kartoza/pg-backup:${POSTGRES_MAJOR}-${POSTGIS_MAJOR}.${POSTGIS_MINOR}`. Always match the PostgreSQL version you're backing up (e.g., use `17-3.5` for backing up a PostgreSQL 17 / PostGIS 3.5 database).

## Important Implementation Notes

- Logging uses a structured `log()` function with optional JSON output (`JSON_LOGGING=true`)
- Retention logic in `scripts/lib/retention.sh` supports both expiry and consolidation (keep one backup per DB per day after N days)
- S3 uploads use retry logic (3 attempts with exponential backoff)
- Encryption uses `openssl enc -aes-256-cbc -pass pass:${PHRASE} -pbkdf2 -iter 10000 -md sha256`
- The `pg_dump` and `pg_restore` commands are executed with `${PG_CONN_PARAMETERS}` which can be fully customized
- Non-root mode creates a user/group and uses `gosu` for privilege dropping
- Table dumps query `information_schema.tables` excluding system schemas (pg_catalog, information_schema, topology, pg_toast)
- Backups generate `.meta.json` metadata files alongside dumps (PG version, encryption status, checksums)
- `BUCKET_PATH` allows organizing backups in a sub-path within the S3 bucket (computed as `S3_DEST=BUCKET/BUCKET_PATH`)

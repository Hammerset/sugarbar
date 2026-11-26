# sugarbar-server

A small sync server for sugarbar: every device keeps working from its own files and syncs Meals, manual Doses and settings, Readings and Glooko Doses through this server into Postgres. The wire contract (v1) and the decisions behind it are in [issue #47](https://github.com/Hammerset/sugarbar/issues/47).

It is a self-contained Swift package (Hummingbird 2 + PostgresNIO) that runs on macOS and Linux, shipped as a container so it runs the same locally, on Fly.io or on Google Cloud Run. Payloads are opaque JSON to the server; it does not depend on `SugarbarCore`.

## Run locally

```sh
cd Server
docker compose up --build -d
docker compose exec server sugarbar-server create-account me
```

The last command prints a token once; only its SHA-256 is stored. Use it as `Authorization: Bearer <token>`. The server listens on `http://localhost:8090` (the host port is `SERVER_HOST_PORT`, Postgres is on `DB_HOST_PORT`, default 55433):

```sh
curl http://localhost:8090/v1/health
curl -H "Authorization: Bearer $TOKEN" "http://localhost:8090/v1/readings?limit=10"
```

Stop with `docker compose down` (add `-v` to also delete the database volume). Set `POSTGRES_PASSWORD` in the environment or a `.env` file next to `docker-compose.yml` for anything beyond a laptop.

The compose project is always named `sugarbar` (containers `sugarbar-db-1` and `sugarbar-server-1`), whichever checkout you run it from. Both containers restart with Docker (`restart: unless-stopped`), so the server comes back after a reboot as long as Docker Desktop starts at login (Settings → General → Start Docker Desktop when you sign in).

### From the iPhone on the same Wi-Fi

The server port listens on all interfaces; Postgres only on `127.0.0.1`. Give the phone the Mac's Bonjour name, which survives DHCP changes: `http://$(scutil --get LocalHostName).local:8090`. The Mac app itself can use `http://localhost:8090`. Both apps allow plain HTTP only to local-network hosts (`NSAllowsLocalNetworking`), and the phone asks for Local Network access on first use. If the macOS firewall is on, Docker.app must be allowed incoming connections (System Settings → Network → Firewall → Options). The phone syncs only while it can reach the Mac; changes made elsewhere wait in the outbox.

Without Docker: `DATABASE_URL=postgres://… swift run sugarbar-server`.

## Configuration

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | required | `postgres://user:password@host:5432/db?sslmode=…`. `sslmode` is `disable`, `prefer` (default), `require` (encrypted, certificate not verified) or `verify-full`. `?host=/cloudsql/<instance>` connects over a Unix socket (Cloud SQL). |
| `PORT` | `8080` | |
| `HOST` | `0.0.0.0` | |
| `LOG_LEVEL` | `info` | |
| `GLOOKO_CREDENTIALS_FILE` | `/var/lib/sugarbar/glooko-credentials.json` in the image, unset otherwise | Where `set-glooko` keeps Glooko logins. Without it the Glooko bridge does not run. |
| `GLOOKO_SIGN_IN_URL` | `https://my.glooko.com/users/sign_in?locale=en-GB` | Only for pointing the bridge at a fake Glooko in tests. |

Migrations run at startup (table `schema_migrations`), so a new version upgrades the schema by itself.

The log has one line per request with method, path, status, duration and account id. Bodies, query strings and tokens are never logged.

## Accounts and tokens

The same binary has admin commands, using `DATABASE_URL` like the server:

```sh
sugarbar-server create-account <name>   # new account, prints its first token
sugarbar-server create-token <name>     # another token for an existing account (e.g. a new device)
sugarbar-server list-accounts
sugarbar-server revoke-token <name>     # revokes every token of that account
```

In compose, prefix with `docker compose exec server`.

## Glooko bridge

The server can send eaten Meals and manual Doses to Glooko, so the care team sees them there, and bring carbs logged in the Glooko app back as Meals. The server is the only writer to Glooko; the apps only switch it on and show what happened. It uses Glooko's unofficial mobile sync API (details and the probe that found it are in [#77](https://github.com/Hammerset/sugarbar/issues/77)), so a Glooko change can break it; when an answer looks wrong the bridge stops sending rather than guess.

Turn it on for an account (here `me`) on the running local server:

```sh
cd Server
docker compose up --build -d
security find-generic-password -s sugarbar-glooko -w | docker compose exec -T server sugarbar-server set-glooko me "you@example.com"
```

`set-glooko <account> <email>` reads the password from stdin and stores it in `GLOOKO_CREDENTIALS_FILE` (mode 0600, on the `secrets` volume in compose). It is never logged and never goes into Postgres, so database dumps do not carry it. `remove-glooko <account>` forgets it. Then switch on **Send to Glooko** in the app (Settings → Accounts & Sync on the Mac, Sync on the iPhone).

What it does, every 5 seconds per account with Send to Glooko on:

- **Follows the `records` sequence.** Each changed `meal` (state `eaten` only) and `manualDose` becomes a Glooko food (`PUT /api/v2/foods`) or a manual insulin entry (`PUT /api/v2/insulins`): create and edit are the same upsert, and a deleted record (or a Meal turned back into a plan) becomes `softDeleted: true`. Only changes made after the bridge was first switched on are sent, for things that happened at most a day before that, so older entries already in Glooko are not doubled.
- **One Glooko entry per record.** The Glooko `guid` is derived from the record id and stored in `glooko_links` before the first write, so a retry after a crash overwrites the same entry. Each item goes in its own request.
- **Removes a manual Dose once its pen dose arrives.** Every 5 minutes it reads the insulin graph around manual Doses it sent in the last 3 days and pairs each with a pen dose of the same kind, units within 0.01 and at most 20 minutes apart, closest first and each pen dose once (the apps' `reconcileDoses` rule). A paired entry is deleted from Glooko and the reason is kept.
- **Imports carbs logged in the Glooko app.** Every 5 minutes it reads the foods change feed (from when the bridge was first switched on). A food it did not write becomes a `meal` record with its own id, so devices get it through normal sync; later edits and deletes in Glooko follow. Its own entries coming back through the feed are recognised by guid and skipped.
- **Times** are written as Glooko wants them, local wall-clock time with a literal `Z`, in the time zone the app sent, using the offset in force at the entry's own moment (so entries either side of a DST change keep their local time).
- **Failures.** A sign-in that fails waits 30 minutes (repeated bad sign-ins could lock the account). Network trouble, 5xx and 429 retry with backoff from 30 seconds up to an hour. A 422 on one item marks that item failed and moves on; it is tried again only when the record changes. Any other 4xx, or an answer that does not look like Glooko's (a write that returns a body, a feed that does not decode), pauses the bridge for the account until Send to Glooko is switched off and on again or `set-glooko` is run.

### Records the bridge adds

These are ordinary `/v1/sync` records, an additive extension of the v1 contract in [#47](https://github.com/Hammerset/sugarbar/issues/47); older apps ignore kinds they do not know.

| kind | id | written by | payload |
|---|---|---|---|
| `glookoSettings` | `default` | the apps | `{"enabled": bool, "timeZone": "Europe/Oslo"}` |
| `glookoBridge` | `status` | the server | `{"state": "ok" \| "off" \| "noLogin" \| "signInFailed" \| "retrying" \| "paused", "message"?: string}` |
| `glookoStatus` | `meal/<id>` or `manualDose/<id>` | the server | `{"state": "waiting" \| "sent" \| "failed" \| "removed" \| "deleted" \| "imported", "message"?: string, "glookoId": string, "echoes"?: [{"kind", "t", "units"}]}` |

`echoes` lists every version of a manual Dose the server wrote to Glooko (kind, epoch seconds, units). Glooko's graph returns those entries without an id, so the apps use the list to drop them from their Glooko Doses; otherwise a manual Dose would count twice once its pen dose arrives. The server writes its records with an `updatedAt` at least a millisecond after the stored copy, so they always land.

Run one server instance per database while the bridge is on: it assumes it is the only writer to `glooko_links`.

## Back up and restore

```sh
docker compose exec -T db pg_dump -U sugarbar -Fc sugarbar > sugarbar-$(date +%F).dump
docker compose exec -T db pg_restore -U sugarbar -d sugarbar --clean --if-exists < sugarbar-2026-11-16.dump
```

For the local server, `backup/install.sh` installs a launchd agent (`com.sugarbar.server-backup`) that runs `backup/backup.sh` daily at 03:30 (or at the next wake): a `pg_dump -Fc` of `sugarbar-db-1` into `~/Documents/privat/sugarbar-backups`, keeping the newest 14 (`SUGARBAR_BACKUP_DIR`, `SUGARBAR_BACKUP_KEEP` override). It logs to `~/Library/Logs/sugarbar-backup.log`; run it at once with `launchctl kickstart gui/$(id -u)/com.sugarbar.server-backup`. Check a dump by restoring it into a throwaway database:

```sh
docker exec sugarbar-db-1 createdb -U sugarbar restore_test
docker exec -i sugarbar-db-1 pg_restore -U sugarbar -d restore_test --no-owner < sugarbar-….dump
docker exec sugarbar-db-1 dropdb -U sugarbar restore_test
```

Against a hosted database, run `pg_dump "$DATABASE_URL" -Fc > …` from any machine with the Postgres client tools. The dump holds health data: keep it encrypted.

## Tests

The integration tests go through the HTTP layer against a real Postgres. Start a throwaway one on port 55432, run the tests, remove it:

```sh
docker run -d --rm --name sugarbar-test-db -p 55432:5432 \
  -e POSTGRES_USER=sugarbar -e POSTGRES_PASSWORD=sugarbar -e POSTGRES_DB=sugarbar_test postgres:17
swift test
docker stop sugarbar-test-db
```

`TEST_DATABASE_URL` points the tests at another database.

## Deploy

Neither deploy below has been tried yet; treat them as a starting point.

**Fly.io (untested).** From `Server/`: `fly launch --no-deploy` (it picks up the Dockerfile; set the internal port to 8080), create a database with `fly postgres create` or use any hosted Postgres, then `fly secrets set DATABASE_URL='postgres://…?sslmode=require'` and `fly deploy`. Create an account with `fly ssh console -C "sugarbar-server create-account me"`.

**Google Cloud Run (untested).** Build and push the image (`gcloud builds submit --tag REGION-docker.pkg.dev/PROJECT/sugarbar/server` from `Server/`), create a Cloud SQL for PostgreSQL instance, then `gcloud run deploy sugarbar-server --image … --add-cloudsql-instances PROJECT:REGION:INSTANCE --set-secrets DATABASE_URL=sugarbar-database-url:latest`, where the secret is `postgres://user:password@/sugarbar?host=/cloudsql/PROJECT:REGION:INSTANCE`. Cloud Run sets `PORT` itself. Run admin commands with a Cloud Run job using the same image and arguments, e.g. `create-account me`.

## How sync stays correct with several devices

Each change in `POST /v1/sync` is an `INSERT … ON CONFLICT … DO UPDATE … WHERE excluded.updated_at > records.updated_at`, so the latest `updatedAt` wins and an equal one keeps the stored record. Accepted writes take the next value of one database sequence as `seq`, and clients pull everything with `seq` above their cursor.

A sequence hands out numbers at call time, not at commit, so with two writers at once `seq` 11 could become visible before `seq` 10 commits; a reader would move its cursor to 11 and never see 10. Writers for one account therefore hold `pg_advisory_xact_lock` until they commit: within an account, `seq`s are committed in the order they were taken, and a reader that sees one also sees every lower one. Different accounts don't wait for each other, and readers never wait. Reading uploads take a second per-account lock, so two devices backfilling at once cannot both store the same Reading.

Glooko Doses (`/v1/doses`) are keyed by id, and the last upload of an id wins. A Dose removed from Glooko is uploaded as a tombstone, `{"id", "t", "payload": {}, "deleted": true}`, and `GET /v1/doses` returns it the same way so every device removes its copy; uploading the Dose again revives it. Apps download Doses before they upload, so a device that still has a deleted Dose learns of the deletion before it could send the Dose back.

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

Without Docker: `DATABASE_URL=postgres://… swift run sugarbar-server`.

## Configuration

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | required | `postgres://user:password@host:5432/db?sslmode=…`. `sslmode` is `disable`, `prefer` (default), `require` (encrypted, certificate not verified) or `verify-full`. `?host=/cloudsql/<instance>` connects over a Unix socket (Cloud SQL). |
| `PORT` | `8080` | |
| `HOST` | `0.0.0.0` | |
| `LOG_LEVEL` | `info` | |

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

## Back up and restore

```sh
docker compose exec -T db pg_dump -U sugarbar -Fc sugarbar > sugarbar-$(date +%F).dump
docker compose exec -T db pg_restore -U sugarbar -d sugarbar --clean --if-exists < sugarbar-2026-11-16.dump
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

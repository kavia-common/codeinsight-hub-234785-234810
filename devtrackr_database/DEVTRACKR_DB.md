# DevTrackr Database (PostgreSQL)

This container runs PostgreSQL and now bootstraps the **DevTrackr** schema automatically.

## How it works

1. `startup.sh` starts PostgreSQL (port 5000), creates database/user, writes:
   - `db_connection.txt` (authoritative connection string)
   - `db_visualizer/postgres.env` (used by the Node DB viewer)
2. `startup.sh` then runs `migrate_and_seed.sh`, which:
   - applies **idempotent** DDL (tables/indexes)
   - inserts minimal seed data (demo org + roles + permissions)

**Important constraint:** `migrate_and_seed.sh` executes SQL **one statement at a time** using `psql -c` (no `.sql` migrations), per container rules.

## Key entities (high level)

### Multi-tenancy / identity
- `organizations`
- `users`
- `oauth_accounts` (GitHub/GitLab identities + tokens)
- `org_memberships`

### RBAC
- `roles`
- `permissions`
- `role_permissions`
- `membership_roles`

### VCS / sync
- `vcs_installations`
- `repositories`
- `repo_sync_runs`
- `commits`
- `pull_requests`
- `pull_request_commits`

### AI + analytics
- `ai_outputs`
- `analytics_daily_org`
- `analytics_daily_repo`

### Compliance / webhooks
- `audit_logs`
- `webhook_deliveries`

### Billing-ready
- `billing_customers`
- `billing_subscriptions`
- `billing_invoices`

## Backend bootstrap notes (FastAPI)

- The backend should use the same connection info as this container.
- For local/dev inside this workspace, you can read:
  - `devtrackr_database/db_connection.txt` (contains `postgresql://...`)

The database credentials currently used by this container are:
- DB: `myapp`
- User: `appuser`
- Password: `dbuser123`
- Port: `5000`

(These are already present in the container scripts; the backend container should instead use env vars via orchestrator mapping.)

## Re-running migrations

You can safely re-run:
- `bash migrate_and_seed.sh`

It is designed to be idempotent (IF NOT EXISTS + ON CONFLICT DO NOTHING).

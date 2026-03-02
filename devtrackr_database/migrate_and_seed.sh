#!/bin/bash
set -euo pipefail

# DevTrackr migration + seed runner
# - Uses db_connection.txt as the authoritative connection string (per container rules)
# - Executes SQL statements ONE AT A TIME via psql -c (per container rules)
# - Idempotent: safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT DO NOTHING)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found. Start DB first (startup.sh) to generate it."
  exit 1
fi

CONN_STR="$(cat db_connection.txt | tr -d '\n')"
if [ -z "${CONN_STR}" ]; then
  echo "ERROR: db_connection.txt is empty."
  exit 1
fi

echo "Running DevTrackr migrations against: ${CONN_STR}"

# Execute exactly one SQL statement per call (CRITICAL RULE).
run_sql () {
  local sql="$1"
  echo "SQL> ${sql}"
  # -v ON_ERROR_STOP=1 ensures psql fails fast if a statement fails
  psql "${CONN_STR}" -v ON_ERROR_STOP=1 -c "${sql}"
}

###############################################################################
# Extensions
###############################################################################
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto"
run_sql "CREATE EXTENSION IF NOT EXISTS citext"

###############################################################################
# Multi-tenancy core
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS organizations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug citext NOT NULL UNIQUE, name text NOT NULL, plan text NOT NULL DEFAULT 'free', is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_organizations_slug ON organizations (slug)"

###############################################################################
# Users + identities (OAuth-ready)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email citext UNIQUE, display_name text, avatar_url text, is_active boolean NOT NULL DEFAULT true, is_superadmin boolean NOT NULL DEFAULT false, last_login_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)"

# OAuth accounts: supports GitHub and GitLab (and future providers)
# Store tokens encrypted-at-rest later via app layer (this schema keeps columns ready).
run_sql "CREATE TABLE IF NOT EXISTS oauth_accounts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, provider text NOT NULL, provider_account_id text NOT NULL, provider_username text, access_token text, refresh_token text, token_type text, scope text, expires_at timestamptz, raw_profile jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(provider, provider_account_id))"
run_sql "CREATE INDEX IF NOT EXISTS idx_oauth_accounts_user_id ON oauth_accounts (user_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_oauth_accounts_provider ON oauth_accounts (provider)"

# Membership
run_sql "CREATE TABLE IF NOT EXISTS org_memberships (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, status text NOT NULL DEFAULT 'active', title text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, user_id))"
run_sql "CREATE INDEX IF NOT EXISTS idx_org_memberships_org_id ON org_memberships (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_org_memberships_user_id ON org_memberships (user_id)"

###############################################################################
# RBAC
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid REFERENCES organizations(id) ON DELETE CASCADE, name text NOT NULL, description text, is_system boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, name))"
run_sql "CREATE INDEX IF NOT EXISTS idx_roles_org_id ON roles (org_id)"

run_sql "CREATE TABLE IF NOT EXISTS permissions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), key text NOT NULL UNIQUE, description text, created_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_permissions_key ON permissions (key)"

run_sql "CREATE TABLE IF NOT EXISTS role_permissions (role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE, permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE, PRIMARY KEY (role_id, permission_id))"

run_sql "CREATE TABLE IF NOT EXISTS membership_roles (membership_id uuid NOT NULL REFERENCES org_memberships(id) ON DELETE CASCADE, role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE, PRIMARY KEY (membership_id, role_id))"

###############################################################################
# Connected VCS installations (org-level)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS vcs_installations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, provider text NOT NULL, external_installation_id text, access_token text, refresh_token text, token_expires_at timestamptz, scope text, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, provider, external_installation_id))"
run_sql "CREATE INDEX IF NOT EXISTS idx_vcs_installations_org_id ON vcs_installations (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_vcs_installations_provider ON vcs_installations (provider)"

###############################################################################
# Repositories + sync tracking
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS repositories (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, provider text NOT NULL, external_repo_id text, full_name text NOT NULL, default_branch text, is_private boolean NOT NULL DEFAULT false, is_archived boolean NOT NULL DEFAULT false, is_active boolean NOT NULL DEFAULT true, installation_id uuid REFERENCES vcs_installations(id) ON DELETE SET NULL, webhook_secret text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, provider, full_name))"
run_sql "CREATE INDEX IF NOT EXISTS idx_repositories_org_id ON repositories (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_repositories_provider ON repositories (provider)"
run_sql "CREATE INDEX IF NOT EXISTS idx_repositories_full_name ON repositories (full_name)"

run_sql "CREATE TABLE IF NOT EXISTS repo_sync_runs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, repo_id uuid NOT NULL REFERENCES repositories(id) ON DELETE CASCADE, started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz, status text NOT NULL DEFAULT 'running', sync_type text NOT NULL DEFAULT 'full', cursor text, stats jsonb, error text, created_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_repo_sync_runs_repo_id ON repo_sync_runs (repo_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_repo_sync_runs_org_id ON repo_sync_runs (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_repo_sync_runs_status ON repo_sync_runs (status)"

###############################################################################
# Commits
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS commits (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, repo_id uuid NOT NULL REFERENCES repositories(id) ON DELETE CASCADE, sha text NOT NULL, author_name text, author_email citext, author_user_id uuid REFERENCES users(id) ON DELETE SET NULL, committed_at timestamptz, message text, additions integer, deletions integer, files_changed integer, url text, raw jsonb, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(repo_id, sha))"
run_sql "CREATE INDEX IF NOT EXISTS idx_commits_repo_id ON commits (repo_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_commits_org_id ON commits (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_commits_committed_at ON commits (committed_at)"
run_sql "CREATE INDEX IF NOT EXISTS idx_commits_author_user_id ON commits (author_user_id)"

###############################################################################
# Pull Requests / Merge Requests (unified)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS pull_requests (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, repo_id uuid NOT NULL REFERENCES repositories(id) ON DELETE CASCADE, provider text NOT NULL, external_pr_id text, number integer, iid integer, title text NOT NULL, body text, state text NOT NULL DEFAULT 'open', url text, author_user_id uuid REFERENCES users(id) ON DELETE SET NULL, author_username text, source_branch text, target_branch text, created_at timestamptz, updated_at timestamptz, merged_at timestamptz, closed_at timestamptz, draft boolean NOT NULL DEFAULT false, raw jsonb, UNIQUE(repo_id, provider, COALESCE(external_pr_id, ''), COALESCE(number, -1), COALESCE(iid, -1)))"
run_sql "CREATE INDEX IF NOT EXISTS idx_pull_requests_repo_id ON pull_requests (repo_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_pull_requests_org_id ON pull_requests (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_pull_requests_state ON pull_requests (state)"
run_sql "CREATE INDEX IF NOT EXISTS idx_pull_requests_created_at ON pull_requests (created_at)"

# PR commits mapping (many-to-many)
run_sql "CREATE TABLE IF NOT EXISTS pull_request_commits (pr_id uuid NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE, commit_id uuid NOT NULL REFERENCES commits(id) ON DELETE CASCADE, PRIMARY KEY (pr_id, commit_id))"

###############################################################################
# AI outputs (summaries, risk, recommendations)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS ai_outputs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, repo_id uuid REFERENCES repositories(id) ON DELETE CASCADE, pr_id uuid REFERENCES pull_requests(id) ON DELETE CASCADE, provider text NOT NULL DEFAULT 'openai', model text, output_type text NOT NULL, prompt text, response text, response_json jsonb, risk_score numeric(5,2), token_usage jsonb, latency_ms integer, created_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_ai_outputs_org_id ON ai_outputs (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_ai_outputs_repo_id ON ai_outputs (repo_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_ai_outputs_pr_id ON ai_outputs (pr_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_ai_outputs_created_at ON ai_outputs (created_at)"

###############################################################################
# Analytics aggregates (materializable later; table-based for now)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS analytics_daily_org (org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, day date NOT NULL, commits_count integer NOT NULL DEFAULT 0, prs_opened_count integer NOT NULL DEFAULT 0, prs_merged_count integer NOT NULL DEFAULT 0, active_developers_count integer NOT NULL DEFAULT 0, avg_pr_cycle_hours numeric(10,2), avg_risk_score numeric(6,2), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (org_id, day))"
run_sql "CREATE INDEX IF NOT EXISTS idx_analytics_daily_org_day ON analytics_daily_org (day)"

run_sql "CREATE TABLE IF NOT EXISTS analytics_daily_repo (repo_id uuid NOT NULL REFERENCES repositories(id) ON DELETE CASCADE, day date NOT NULL, commits_count integer NOT NULL DEFAULT 0, prs_opened_count integer NOT NULL DEFAULT 0, prs_merged_count integer NOT NULL DEFAULT 0, avg_pr_cycle_hours numeric(10,2), avg_risk_score numeric(6,2), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (repo_id, day))"
run_sql "CREATE INDEX IF NOT EXISTS idx_analytics_daily_repo_day ON analytics_daily_repo (day)"

###############################################################################
# Audit logs (security/compliance)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS audit_logs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid REFERENCES organizations(id) ON DELETE CASCADE, actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL, actor_ip inet, actor_user_agent text, action text NOT NULL, entity_type text, entity_id uuid, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now())"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_org_id ON audit_logs (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_user_id ON audit_logs (actor_user_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs (created_at)"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs (action)"

###############################################################################
# Webhook deliveries (GitHub/GitLab)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS webhook_deliveries (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid REFERENCES organizations(id) ON DELETE CASCADE, repo_id uuid REFERENCES repositories(id) ON DELETE CASCADE, provider text NOT NULL, event text NOT NULL, delivery_id text, request_headers jsonb, request_body jsonb, response_status integer, response_headers jsonb, response_body text, error text, received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz, status text NOT NULL DEFAULT 'received')"
run_sql "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_org_id ON webhook_deliveries (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_repo_id ON webhook_deliveries (repo_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_provider_event ON webhook_deliveries (provider, event)"
run_sql "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_received_at ON webhook_deliveries (received_at)"
run_sql "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_status ON webhook_deliveries (status)"

###############################################################################
# Billing-ready entities (Stripe-ready, but provider-agnostic)
###############################################################################
run_sql "CREATE TABLE IF NOT EXISTS billing_customers (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, provider text NOT NULL DEFAULT 'stripe', external_customer_id text, email citext, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, provider))"
run_sql "CREATE INDEX IF NOT EXISTS idx_billing_customers_org_id ON billing_customers (org_id)"

run_sql "CREATE TABLE IF NOT EXISTS billing_subscriptions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, customer_id uuid REFERENCES billing_customers(id) ON DELETE SET NULL, provider text NOT NULL DEFAULT 'stripe', external_subscription_id text, status text NOT NULL DEFAULT 'inactive', plan_key text, current_period_start timestamptz, current_period_end timestamptz, cancel_at_period_end boolean NOT NULL DEFAULT false, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, provider))"
run_sql "CREATE INDEX IF NOT EXISTS idx_billing_subscriptions_org_id ON billing_subscriptions (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_billing_subscriptions_status ON billing_subscriptions (status)"

run_sql "CREATE TABLE IF NOT EXISTS billing_invoices (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, subscription_id uuid REFERENCES billing_subscriptions(id) ON DELETE SET NULL, provider text NOT NULL DEFAULT 'stripe', external_invoice_id text, status text, amount_due_cents integer, amount_paid_cents integer, currency text, hosted_invoice_url text, invoice_pdf_url text, issued_at timestamptz, paid_at timestamptz, raw jsonb, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(org_id, provider, external_invoice_id))"
run_sql "CREATE INDEX IF NOT EXISTS idx_billing_invoices_org_id ON billing_invoices (org_id)"
run_sql "CREATE INDEX IF NOT EXISTS idx_billing_invoices_status ON billing_invoices (status)"

###############################################################################
# Minimal seed data (permissions + default org/roles)
###############################################################################
# Permissions (expand later as backend endpoints solidify)
run_sql "INSERT INTO permissions (key, description) VALUES ('org:read','Read organization'), ('org:admin','Admin organization'), ('repo:read','Read repositories'), ('repo:write','Manage repositories'), ('sync:run','Run sync jobs'), ('ai:use','Use AI features'), ('audit:read','Read audit logs'), ('billing:manage','Manage billing') ON CONFLICT (key) DO NOTHING"

# Default organization + roles
run_sql "INSERT INTO organizations (slug, name, plan) VALUES ('demo', 'Demo Organization', 'free') ON CONFLICT (slug) DO NOTHING"
run_sql "INSERT INTO roles (org_id, name, description, is_system) SELECT o.id, 'owner', 'Organization owner', true FROM organizations o WHERE o.slug='demo' ON CONFLICT (org_id, name) DO NOTHING"
run_sql "INSERT INTO roles (org_id, name, description, is_system) SELECT o.id, 'admin', 'Organization admin', true FROM organizations o WHERE o.slug='demo' ON CONFLICT (org_id, name) DO NOTHING"
run_sql "INSERT INTO roles (org_id, name, description, is_system) SELECT o.id, 'member', 'Organization member', true FROM organizations o WHERE o.slug='demo' ON CONFLICT (org_id, name) DO NOTHING"

# Map permissions to roles (owner gets all)
run_sql "INSERT INTO role_permissions (role_id, permission_id) SELECT r.id, p.id FROM roles r JOIN organizations o ON o.id=r.org_id JOIN permissions p ON true WHERE o.slug='demo' AND r.name='owner' ON CONFLICT DO NOTHING"
# admin gets most
run_sql "INSERT INTO role_permissions (role_id, permission_id) SELECT r.id, p.id FROM roles r JOIN organizations o ON o.id=r.org_id JOIN permissions p ON p.key IN ('org:read','org:admin','repo:read','repo:write','sync:run','ai:use','audit:read','billing:manage') WHERE o.slug='demo' AND r.name='admin' ON CONFLICT DO NOTHING"
# member gets read + ai
run_sql "INSERT INTO role_permissions (role_id, permission_id) SELECT r.id, p.id FROM roles r JOIN organizations o ON o.id=r.org_id JOIN permissions p ON p.key IN ('org:read','repo:read','ai:use') WHERE o.slug='demo' AND r.name='member' ON CONFLICT DO NOTHING"

echo "✅ DevTrackr migrations + seed completed successfully."
echo "Tip: re-run this script anytime; it is safe and idempotent."

# pdl-test — Makefile
#
# Operator-facing entry points for the local dev environment.
# Infrastructure (Postgres, Flyway, MinIO) runs in docker compose; the
# Python ingester, PDL API callers, dbt, tests and lint run on the host in
# the `pdl_test` conda env. Activate it first:
#
#   conda env create -f environment.yml   # once
#   conda activate pdl_test
#
# Quick start:
#   make dev-up               # core: postgres + flyway + fixture
#   make dev-up-ingester      # + minio (for s3_ingester e2e)
#   make ingest-pdl           # Python ingester only (Finder→Loader→Projection)
#   make dbt-pdl              # dbt only (build tag:pdl+ downstream)
#   make pipeline-pdl         # full chain: ingest-pdl + dbt-pdl
#   make clean-pdl            # PDL cleaners (live API, needs PDL_API_KEY)
#   make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n   # PDL company enrichment (live API)
#   make test / make lint     # pytest / ruff
#   make dev-reset            # nuke ALL volumes, start over
#
# See docs/design/local-dev-design.md for the architecture rationale.

# Use bash so we get pipefail + brace expansion + heredocs.
SHELL := /usr/bin/env bash
.ONESHELL:

COMPOSE := docker compose

# ── Host-side connection settings (match docker-compose.yml) ──────────
# Override on the command line, e.g. `make ingest-pdl DELIVERY_DATE=2026_06_01`.
PG_USER     ?= pdl_etl
PG_PASSWORD ?= pdl_etl_dev
PG_DB       ?= pdl_etl
PG_HOST     ?= localhost
PG_PORT     ?= 5432

MINIO_USER     ?= minio_local
MINIO_PASSWORD ?= minio_local_dev
LOCAL_BUCKET   ?= pdl-ingest-local
DELIVERY_DATE  ?= 2026_05_22

# Env for host-side Python (ingester + PDL API callers): local Postgres +
# boto3 pointed at MinIO. PDL_API_KEY is inherited from your shell.
INGEST_ENV := \
    DATABASE_URL=postgresql://$(PG_USER):$(PG_PASSWORD)@$(PG_HOST):$(PG_PORT)/$(PG_DB) \
    AWS_ENDPOINT_URL=http://localhost:9000 \
    AWS_ACCESS_KEY_ID=$(MINIO_USER) \
    AWS_SECRET_ACCESS_KEY=$(MINIO_PASSWORD) \
    AWS_DEFAULT_REGION=us-east-1

# Env for dbt's `local` target (processing/dbt/profiles.yml reads DBT_PG_*).
DBT_ENV := \
    DBT_TARGET=local \
    DBT_PG_HOST=$(PG_HOST) \
    DBT_PG_PORT=$(PG_PORT) \
    DBT_PG_USER=$(PG_USER) \
    DBT_PG_PASSWORD=$(PG_PASSWORD) \
    DBT_PG_DBNAME=$(PG_DB)

# Helpful echo coloring (NO_COLOR=1 to disable).
ifndef NO_COLOR
  GREEN := \033[1;32m
  CYAN  := \033[1;36m
  YELLOW:= \033[1;33m
  RESET := \033[0m
else
  GREEN :=
  CYAN  :=
  YELLOW:=
  RESET :=
endif

.PHONY: help
help: ## show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Host targets (ingest-*, dbt-*, pipeline-*, *-pdl, test, lint) expect the"
	@echo "  pdl_test conda env to be active:  conda activate pdl_test"
	@echo ""
	@echo "  Core targets:    dev-up, dev-up-ingester, dev-down, dev-reset"
	@echo "  Ingester only:   ingest-pdl"
	@echo "  dbt only:        dbt-pdl, dbt-integration, dbt-<tag>"
	@echo "  Full chain:      pipeline-pdl  (= ingest-pdl + dbt-pdl)"
	@echo "  PDL API (live):  clean-pdl, enrich-pdl  (need PDL_API_KEY)"
	@echo "  Dev:             test, lint"
	@echo "  Lifecycle:       dev-logs, dev-ps"

# ──────────────────────────────────────────────────────────────────
# Core lifecycle (docker compose)
# ──────────────────────────────────────────────────────────────────

.PHONY: dev-up
dev-up: ## bring up core services (postgres + flyway-init + fixture-load)
	$(COMPOSE) up -d postgres
	@printf "$(YELLOW)waiting for postgres ready...$(RESET)\n"
	@# Poll pg_isready inside the container: needs no host tools beyond
	@# docker (parsing `compose ps --format json` would need jq and differs
	@# across compose versions).
	@until $(COMPOSE) exec -T postgres pg_isready -U $(PG_USER) -d $(PG_DB) >/dev/null 2>&1; do sleep 1; done
	$(COMPOSE) up flyway-init fixture-load
	@printf "\n$(GREEN)✓ dev environment ready$(RESET)\n"
	@printf "  postgres:    localhost:5432  (user=$(PG_USER), pw=$(PG_PASSWORD), db=$(PG_DB))\n"
	@printf "  connect via your host pgAdmin app, or import infra/local/pgadmin/local-server.json\n"
	@printf "\n  Next steps (conda activate pdl_test first):\n"
	@printf "    $(CYAN)make dbt-pdl$(RESET)                # build PDL dbt models\n"
	@printf "    $(CYAN)make dev-up-ingester$(RESET)        # + MinIO for s3_ingester e2e\n"

.PHONY: dev-up-ingester
dev-up-ingester: ## bring up core + ingester profile (raw.pdl_person stays empty; ingester populates it)
	@# SKIP_RAW_LOAD=1 keeps raw.pdl_person empty so `make ingest-pdl`
	@# can populate it via the real Finder → Loader → Projection chain.
	SKIP_RAW_LOAD=1 $(COMPOSE) up -d postgres
	@printf "$(YELLOW)waiting for postgres ready...$(RESET)\n"
	@until $(COMPOSE) exec -T postgres pg_isready -U $(PG_USER) -d $(PG_DB) >/dev/null 2>&1; do sleep 1; done
	SKIP_RAW_LOAD=1 $(COMPOSE) up flyway-init fixture-load
	$(COMPOSE) --profile ingester up -d minio
	@printf "$(YELLOW)waiting for minio ready...$(RESET)\n"
	@# Read Docker's own healthcheck state via `docker inspect`. The minio
	@# image carries an internal HEALTHCHECK directive that Compose uses
	@# (visible as `(healthy)` in `compose ps`); inspecting it sidesteps
	@# needing any host tool (no jq) OR any in-container tool (the minio
	@# image ships neither wget nor curl). Returns "healthy" once ready.
	@until [ "$$(docker inspect --format '{{.State.Health.Status}}' pdl_test_minio 2>/dev/null)" = "healthy" ]; do sleep 1; done
	@# --no-deps stops compose from re-running fixture-load through
	@# minio-init's `depends_on`; that re-run would not see SKIP_RAW_LOAD and
	@# would load raw.pdl_person directly. SKIP_RAW_LOAD=1 is repeated here as
	@# a second guard.
	SKIP_RAW_LOAD=1 DELIVERY_DATE=$(DELIVERY_DATE) $(COMPOSE) --profile ingester up --no-deps minio-init
	@printf "\n$(GREEN)✓ ingester profile ready$(RESET)\n"
	@printf "  minio S3 API: localhost:9000  (boto3 endpoint)\n"
	@printf "  minio console: http://localhost:9001  (user=$(MINIO_USER), pw=$(MINIO_PASSWORD))\n"
	@printf "  bucket:       $(LOCAL_BUCKET)\n"
	@printf "  fixture path: $(DELIVERY_DATE)/data/part-00000.csv.gz + $(DELIVERY_DATE)/COMPLETED\n"
	@printf "\n  Try:  $(CYAN)make ingest-pdl$(RESET)     # PDL Finder → Loader → Projection only\n"
	@printf "        $(CYAN)make pipeline-pdl$(RESET)   # full chain: ingester + dbt\n"

.PHONY: dev-down
dev-down: ## stop services, keep volumes (data persists)
	$(COMPOSE) --profile ingester down

.PHONY: dev-reset
dev-reset: ## NUKE: stop services + drop volumes + clear fixture cache
	$(COMPOSE) --profile ingester down -v
	@rm -rf infra/local/fixtures-cache/*
	@printf "$(GREEN)✓ all data wiped. Run \`make dev-up\` to start over.$(RESET)\n"

.PHONY: dev-ps
dev-ps: ## list running services (across all profiles)
	$(COMPOSE) --profile ingester ps

.PHONY: dev-logs
dev-logs: ## tail logs from all running services
	$(COMPOSE) --profile ingester logs -f --tail=50

# ──────────────────────────────────────────────────────────────────
# Pipeline runs (host, pdl_test conda env; chains the modules directly)
# ──────────────────────────────────────────────────────────────────
#
# Target shape:
#   - Python ingester only:  `ingest-pdl`           (raw.* populated from MinIO)
#   - dbt only:              `dbt-<tag>`            (build staging + downstream)
#   - Full chain:            `pipeline-pdl`         (= ingest-pdl + dbt-pdl)

.PHONY: ingest-pdl
ingest-pdl: ## run the PDL ingester (Finder → Loader → Projection) against MinIO
	@# --source pdl_full_local picks up configs/pdl_full_local.yaml, which
	@# differs from pdl_full.yaml only in bucket=pdl-ingest-local.
	@# AWS_ENDPOINT_URL=http://localhost:9000 routes boto3 at MinIO instead
	@# of real S3.
	$(INGEST_ENV) python -m processing.s3_ingester.run \
	    --source pdl_full_local \
	    --delivery-date $(DELIVERY_DATE) \
	    --max-concurrency 2

# dbt source-tag builds. Two ways to invoke:
#   - named alias (surfaced in `make help`, tab-completable): make dbt-pdl
#   - pattern rule (works for any new tag without editing):   make dbt-<newtag>
# `tag:<x>+` selects the tagged staging model AND all downstream descendants.
# Tags are defined in processing/dbt/dbt_project.yml.
#
# Requires processing/dbt/profiles.yml (copy from profiles.yml.example once).
#
# Why this isn't `dbt-pdl: ## …` (empty) + a pattern rule alone: GNU Make
# treats a PHONY target with no recipe as satisfied without consulting the
# pattern rule, so empty stubs would silently no-op. Each named alias gets
# an explicit recipe via $(call DBT_BUILD,<tag>) to force the recipe to run.
DBT_BUILD = cd processing/dbt && $(DBT_ENV) dbt build \
                --profiles-dir . --project-dir . --select tag:$(1)+

.PHONY: dbt-pdl dbt-integration
dbt-pdl:         ## build PDL staging + downstream
	$(call DBT_BUILD,pdl)
dbt-integration: ## build integration models
	$(call DBT_BUILD,integration)

# Open-ended pattern rule for any other tag. Example: after adding tag:foo
# in dbt_project.yml, `make dbt-foo` works without touching this file.
dbt-%:
	$(call DBT_BUILD,$*)

.PHONY: pipeline-pdl
pipeline-pdl: ingest-pdl dbt-pdl ## full PDL chain: ingest + dbt

# ──────────────────────────────────────────────────────────────────
# PDL API (live, billable — needs PDL_API_KEY in the environment)
# ──────────────────────────────────────────────────────────────────
#
# Both targets refuse to run without PDL_API_KEY so nothing reaches PDL by
# accident. They drain the pdl_api.* queue tables, which must be populated
# first. enrich-pdl uses the default bulk rate (PDL_RPM applies to clean-pdl).

PDL_RPM      ?=
SOURCE_LIST  ?=
MAX_CREDITS  ?=

REQUIRE_PDL_KEY = @test -n "$$PDL_API_KEY" || \
    { echo "PDL_API_KEY is not set — refusing to call the PDL API."; exit 1; }

.PHONY: clean-pdl
clean-pdl: ## PDL cleaners: drain company, location, school queues (PDL_RPM=N optional)
	$(REQUIRE_PDL_KEY)
	$(INGEST_ENV) python -m processing.pdl_api.company_cleaner drain $(if $(PDL_RPM),--rpm $(PDL_RPM))
	$(INGEST_ENV) python -m processing.pdl_api.location_cleaner drain $(if $(PDL_RPM),--rpm $(PDL_RPM))
	$(INGEST_ENV) python -m processing.pdl_api.school_cleaner drain $(if $(PDL_RPM),--rpm $(PDL_RPM))

.PHONY: enrich-pdl
enrich-pdl: ## PDL company enrichment: SOURCE_LIST=x MAX_CREDITS=n required
	$(REQUIRE_PDL_KEY)
	@test -n "$(SOURCE_LIST)" -a -n "$(MAX_CREDITS)" || \
	    { echo "usage: make enrich-pdl SOURCE_LIST=<list> MAX_CREDITS=<n>"; exit 1; }
	$(INGEST_ENV) python -m processing.pdl_api.company_enrichment run \
	    --source-list $(SOURCE_LIST) --max-credits $(MAX_CREDITS)

# ──────────────────────────────────────────────────────────────────
# Dev checks (host, pdl_test conda env)
# ──────────────────────────────────────────────────────────────────

.PHONY: test
test: ## run pytest (integration tests auto-skip unless DATABASE_URL is set)
	python -m pytest -q -p no:cacheprovider

.PHONY: lint
lint: ## run ruff over processing/
	ruff check processing

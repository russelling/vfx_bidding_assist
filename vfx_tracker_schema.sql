-- =============================================================================
-- VFX FINANCIAL TRACKER — FULL POSTGRESQL SCHEMA
-- =============================================================================
-- Conventions:
--   • All PKs are UUIDs (portable, no collision across environments)
--   • created_at / updated_at on every table (trigger-managed)
--   • Monetary amounts stored as NUMERIC(15,4) — supports all currencies
--   • Soft-delete via deleted_at where data must be preserved for audit
--   • Enums defined as PG types for type-safety
--   • All FKs have explicit ON DELETE behaviour documented
-- =============================================================================


-- ---------------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- fuzzy text search on shot codes / scene headings


-- ---------------------------------------------------------------------------
-- UTILITY: auto-update updated_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Macro to attach the trigger to any table
-- Usage: SELECT attach_updated_at('table_name');
CREATE OR REPLACE FUNCTION attach_updated_at(tbl TEXT)
RETURNS VOID AS $$
BEGIN
  EXECUTE FORMAT(
    'CREATE TRIGGER set_updated_at
     BEFORE UPDATE ON %I
     FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();', tbl);
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- SECTION 1: ENUMERATIONS
-- =============================================================================

CREATE TYPE project_status AS ENUM (
  'development',    -- early pre-production, budgeting phase
  'bidding',        -- RFQs out to vendors
  'awarded',        -- vendors selected, production underway
  'post',           -- active post-production
  'delivery',       -- final deliveries in progress
  'complete',       -- all deliveries accepted
  'cancelled'
);

CREATE TYPE script_status AS ENUM (
  'received',       -- PDF received, not yet parsed
  'parsing',        -- automated parse in progress
  'review',         -- parsed, awaiting human review
  'approved',       -- confirmed as source of truth for this version
  'superseded'      -- a newer draft has been approved
);

CREATE TYPE shot_status AS ENUM (
  'omit',           -- cut from project
  'concept',        -- identified from script, not yet bid
  'bid_pending',    -- included in an RFQ, awaiting vendor response
  'bid_received',   -- at least one bid received
  'awarded',        -- vendor selected
  'in_progress',    -- work underway
  'internal_review',
  'client_review',
  'approved',
  'final_delivered'
);

CREATE TYPE asset_type AS ENUM (
  'cg_character',
  'cg_vehicle',
  'cg_environment',
  'cg_prop',
  'cg_creature',
  'matte_painting',
  'plate',
  'stock_element',
  'scan_data',
  'lidar',
  'previs',
  'other'
);

CREATE TYPE task_type AS ENUM (
  '2d_comp',
  '3d_comp',
  'roto',
  'paint',
  'tracking',
  'matchmove',
  'fx_simulation',
  'lighting',
  'rendering',
  'modelling',
  'rigging',
  'animation',
  'matte_painting',
  'colour_grade',
  'stereo_conversion',
  'previs',
  'techvis',
  'supervision',
  'data_io',
  'other'
);

CREATE TYPE rfq_status AS ENUM (
  'draft',
  'sent',
  'acknowledged',   -- vendor confirmed receipt
  'in_progress',    -- vendor actively bidding
  'submitted',      -- bid received
  'closed',
  'cancelled'
);

CREATE TYPE bid_status AS ENUM (
  'draft',
  'submitted',
  'under_review',
  'shortlisted',
  'awarded',
  'rejected',
  'withdrawn'
);

CREATE TYPE change_order_status AS ENUM (
  'draft',
  'pending_approval',
  'approved',
  'rejected',
  'void'
);

CREATE TYPE project_type AS ENUM (
  'feature',        -- theatrical feature film
  'series',         -- episodic TV / streaming series
  'short',          -- short film
  'commercial',     -- advertising / branded content
  'documentary',    -- documentary feature or series
  'other'
);

CREATE TYPE scene_time AS ENUM ('day', 'night', 'dawn', 'dusk', 'unknown');
CREATE TYPE scene_location AS ENUM ('interior', 'exterior', 'int_ext', 'unknown');

CREATE TYPE currency_code AS ENUM (
  'USD', 'GBP', 'EUR', 'CAD', 'AUD', 'NZD',
  'HUF', 'CZK', 'PLN', 'RON', 'BGN',   -- eastern Europe rebate territories
  'ZAR', 'INR', 'CNY', 'JPY', 'KRW',
  'BRL', 'MXN', 'SGD', 'HKD'
);

CREATE TYPE report_type AS ENUM (
  'cost_summary',
  'vendor_comparison',
  'budget_vs_actual',
  'change_order_log',
  'shot_status',
  'delivery_schedule'
);


-- =============================================================================
-- SECTION 2: CORE PROJECT & USERS
-- =============================================================================

CREATE TABLE users (
  -- Make the ID match the Supabase Auth UUID
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           TEXT NOT NULL UNIQUE,
  full_name       TEXT NOT NULL,
  role            TEXT NOT NULL DEFAULT 'coordinator',  
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('users');


-- ---------------------------------------------------------------------------
CREATE TABLE projects (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code                TEXT NOT NULL UNIQUE,           -- e.g. 'PROJ-2025-001'
  title               TEXT NOT NULL,
  project_type        project_type NOT NULL DEFAULT 'feature',
  client_name         TEXT,
  production_company  TEXT,
  director            TEXT,
  vfx_supervisor      TEXT,
  vfx_producer        UUID REFERENCES users(id) ON DELETE SET NULL,
  status              project_status NOT NULL DEFAULT 'development',
  base_currency       currency_code NOT NULL DEFAULT 'USD',

  -- Budget envelope
  approved_budget     NUMERIC(15,4),
  contingency_pct     NUMERIC(5,2) DEFAULT 10.00,    -- % added on top of awarded costs

  -- Schedule
  shoot_start_date    DATE,
  shoot_end_date      DATE,
  post_start_date     DATE,
  delivery_date       DATE,

  notes               TEXT,
  deleted_at          TIMESTAMPTZ,                   -- soft delete
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('projects');

CREATE INDEX idx_projects_status ON projects(status) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Project team membership
CREATE TABLE project_members (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id  UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role        TEXT NOT NULL DEFAULT 'coordinator',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, user_id)
);


-- =============================================================================
-- SECTION 2B: EPISODES (series projects only)
-- =============================================================================
-- Episodes exist only when project.project_type = 'series'.
-- For features, scripts attach directly to the project (episode_id is NULL).

CREATE TABLE episodes (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

  episode_number      INTEGER NOT NULL,               -- 1, 2, 3 …
  episode_code        TEXT NOT NULL,                  -- e.g. 'S01E04', 'EP104'
  title               TEXT,
  air_date            DATE,
  runtime_minutes     INTEGER,

  -- Schedule
  shoot_start_date    DATE,
  shoot_end_date      DATE,
  post_start_date     DATE,
  delivery_date       DATE,

  -- Budget envelope (episodes can have their own sub-budgets)
  approved_budget     NUMERIC(15,4),

  notes               TEXT,
  deleted_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, episode_number)
);
SELECT attach_updated_at('episodes');

CREATE INDEX idx_episodes_project ON episodes(project_id) WHERE deleted_at IS NULL;




CREATE TABLE scripts (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  episode_id      UUID REFERENCES episodes(id) ON DELETE CASCADE,  -- NULL for features
  version_label   TEXT NOT NULL,                     -- e.g. 'Draft 1', 'Pink Pages', 'Locked'
  version_number  INTEGER NOT NULL DEFAULT 1,
  received_date   DATE NOT NULL DEFAULT CURRENT_DATE,
  pdf_path        TEXT,                              -- storage path / S3 key
  pdf_hash        TEXT,                              -- SHA-256 of PDF for change detection
  status          script_status NOT NULL DEFAULT 'received',

  -- Import record
  imported_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  imported_at     TIMESTAMPTZ,                       -- when the PDF was uploaded
  import_notes    TEXT,                              -- e.g. 'received via email from production'

  parsed_at       TIMESTAMPTZ,
  reviewed_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at     TIMESTAMPTZ,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, episode_id, version_number)
);
SELECT attach_updated_at('scripts');

-- ---------------------------------------------------------------------------
-- Scenes extracted from scripts
CREATE TABLE scenes (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  script_id           UUID NOT NULL REFERENCES scripts(id) ON DELETE CASCADE,
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  episode_id          UUID REFERENCES episodes(id) ON DELETE CASCADE,  -- NULL for features

  scene_number        TEXT NOT NULL,                 -- '42', '42A', 'OMIT'
  sequence_order      INTEGER,                       -- parse order within script
  slug_line           TEXT,                          -- full INT/EXT. LOCATION - TIME
  location_name       TEXT,
  int_ext             scene_location DEFAULT 'unknown',  -- INT / EXT / INT/EXT
  time_of_day         scene_time DEFAULT 'unknown',

  -- Page references (industry standard: counted in 1/8 page increments)
  -- Store as NUMERIC so 4⅜ pages = 4.375; application displays as fractions
  start_page          NUMERIC(6,3),                  -- first page this scene appears on
  end_page            NUMERIC(6,3),                  -- last page this scene appears on
  page_count          NUMERIC(6,3),                  -- scene length in 1/8-page units
                                                     -- e.g. 1.125 = 1⅛ pages; generated
                                                     -- or set directly if parser provides it

  synopsis            TEXT,                          -- brief description from parser

  -- VFX flags set by parser / supervisor review
  has_vfx             BOOLEAN NOT NULL DEFAULT FALSE,
  vfx_complexity      SMALLINT CHECK (vfx_complexity BETWEEN 1 AND 5),  -- 1=trivial 5=hero
  vfx_notes           TEXT,

  -- Change tracking between script versions
  is_new              BOOLEAN DEFAULT FALSE,         -- added in this draft
  is_modified         BOOLEAN DEFAULT FALSE,         -- changed from prior draft
  is_omitted          BOOLEAN DEFAULT FALSE,         -- omitted in this draft
  prior_scene_id      UUID REFERENCES scenes(id) ON DELETE SET NULL,  -- link to previous version

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (script_id, scene_number)
);
SELECT attach_updated_at('scenes');

CREATE INDEX idx_scenes_project ON scenes(project_id);
CREATE INDEX idx_scenes_has_vfx ON scenes(project_id, has_vfx) WHERE has_vfx = TRUE;

-- ---------------------------------------------------------------------------
-- Script diff log: machine-generated record of changes between versions
CREATE TABLE script_diffs (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  from_script_id      UUID REFERENCES scripts(id) ON DELETE SET NULL,
  to_script_id        UUID NOT NULL REFERENCES scripts(id) ON DELETE CASCADE,
  diff_generated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  scenes_added        INTEGER DEFAULT 0,
  scenes_modified     INTEGER DEFAULT 0,
  scenes_omitted      INTEGER DEFAULT 0,
  shots_affected      INTEGER DEFAULT 0,             -- populated after bid recalculation
  estimated_cost_delta NUMERIC(15,4),
  summary             TEXT,
  reviewed_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =============================================================================
-- SECTION 4: SHOTS & ASSETS
-- =============================================================================

CREATE TABLE shots (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  episode_id          UUID REFERENCES episodes(id) ON DELETE SET NULL,
  scene_id            UUID REFERENCES scenes(id) ON DELETE SET NULL,  -- links to approved script's scene

  shot_code           TEXT NOT NULL,                 -- e.g. 'sc042_sh010'
  status              shot_status NOT NULL DEFAULT 'concept',
  complexity          SMALLINT CHECK (complexity BETWEEN 1 AND 5),
  priority            SMALLINT CHECK (priority BETWEEN 1 AND 3) DEFAULT 2,  -- 1=hero 3=background

  -- Shot descriptions
  description         TEXT,                          -- general editorial description
  vfx_description     TEXT,                          -- what the VFX work is (client-facing)
  vfx_notes           TEXT,                          -- technical VFX notes (vendor-facing)
  internal_notes      TEXT,                          -- internal production notes only

  -- Tags (text array; also auto-populated by task trigger — see Section 4B)
  tags                TEXT[] NOT NULL DEFAULT '{}',

  -- Plate / camera info
  plate_duration_frames INTEGER,
  frame_rate          TEXT DEFAULT '24',             -- '24', '25', '29.97', etc.
  resolution          TEXT DEFAULT '4K',

  -- Editorial
  cut_duration_frames INTEGER,
  first_frame         INTEGER,
  last_frame          INTEGER,

  -- Flow / ShotGrid sync
  flow_shot_id        TEXT,                          -- Autodesk Flow entity ID
  flow_synced_at      TIMESTAMPTZ,

  deleted_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, shot_code)
);
SELECT attach_updated_at('shots');

CREATE INDEX idx_shots_project ON shots(project_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_shots_scene ON shots(scene_id);
CREATE INDEX idx_shots_status ON shots(project_id, status);
CREATE INDEX idx_shots_flow ON shots(flow_shot_id) WHERE flow_shot_id IS NOT NULL;

-- ---------------------------------------------------------------------------
CREATE TABLE assets (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  asset_type      asset_type NOT NULL,
  description     TEXT,

  -- Flow sync
  flow_asset_id   TEXT,
  flow_synced_at  TIMESTAMPTZ,

  deleted_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('assets');

-- Many-to-many: shots ↔ assets
CREATE TABLE shot_assets (
  shot_id     UUID NOT NULL REFERENCES shots(id) ON DELETE CASCADE,
  asset_id    UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (shot_id, asset_id)
);

-- ---------------------------------------------------------------------------
-- Tasks: the billable work units within a shot
CREATE TABLE tasks (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  shot_id             UUID NOT NULL REFERENCES shots(id) ON DELETE CASCADE,
  task_type           task_type NOT NULL,
  description         TEXT,
  sequence_order      INTEGER DEFAULT 1,             -- display order within shot

  -- Cost resolution (three-tier: global default → project default → task override)
  -- The application resolves: task_cost_override ?? project_default ?? global_default
  global_default_cost NUMERIC(15,4),                 -- copied from task_cost_defaults at creation
  project_default_cost NUMERIC(15,4),                -- copied from project_task_defaults at creation
  task_cost_override  NUMERIC(15,4),                 -- set by user to override both defaults

  -- Resolved cost (stored for query performance; updated by trigger when any cost field changes)
  estimated_cost      NUMERIC(15,4)
    GENERATED ALWAYS AS (
      COALESCE(task_cost_override, project_default_cost, global_default_cost)
    ) STORED,

  -- Actuals (filled during production)
  actual_cost         NUMERIC(15,4),

  -- Flow task sync
  flow_task_id        TEXT,
  flow_synced_at      TIMESTAMPTZ,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('tasks');

CREATE INDEX idx_tasks_shot ON tasks(shot_id);

-- ---------------------------------------------------------------------------
-- SECTION 4B: TASK TAG TRIGGER
-- When a task is inserted or its task_type changes, write the task_type label
-- back into shots.tags so each shot shows its work types at a glance.
-- When a task is deleted, the tag is removed if no other task of that type remains.

CREATE OR REPLACE FUNCTION sync_shot_tags()
RETURNS TRIGGER AS $$
DECLARE
  v_shot_id UUID;
  v_tag     TEXT;
BEGIN
  -- Determine which shot and tag we're dealing with
  v_shot_id := COALESCE(NEW.shot_id, OLD.shot_id);
  v_tag     := COALESCE(NEW.task_type::TEXT, OLD.task_type::TEXT);

  IF TG_OP = 'DELETE' THEN
    -- Only remove tag if no other task of the same type remains on this shot
    IF NOT EXISTS (
      SELECT 1 FROM tasks
      WHERE shot_id = v_shot_id
        AND task_type = OLD.task_type
        AND id != OLD.id
    ) THEN
      UPDATE shots SET tags = array_remove(tags, v_tag) WHERE id = v_shot_id;
    END IF;
    RETURN OLD;
  END IF;

  -- INSERT or UPDATE: add the tag if not already present
  UPDATE shots
  SET tags = CASE
    WHEN v_tag = ANY(tags) THEN tags
    ELSE array_append(tags, v_tag)
  END
  WHERE id = v_shot_id;

  -- If task_type changed on UPDATE, clean up the old tag
  IF TG_OP = 'UPDATE' AND OLD.task_type IS DISTINCT FROM NEW.task_type THEN
    IF NOT EXISTS (
      SELECT 1 FROM tasks
      WHERE shot_id = v_shot_id
        AND task_type = OLD.task_type
        AND id != OLD.id
    ) THEN
      UPDATE shots SET tags = array_remove(tags, OLD.task_type::TEXT) WHERE id = v_shot_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER task_tag_sync
  AFTER INSERT OR UPDATE OF task_type OR DELETE ON tasks
  FOR EACH ROW EXECUTE FUNCTION sync_shot_tags();

CREATE INDEX idx_shots_tags ON shots USING GIN(tags);


-- =============================================================================
-- SECTION 5: TASK COST DEFAULTS
-- =============================================================================
-- Two-tier default cost system:
--   1. task_cost_defaults  — global defaults (system-wide, admin-managed)
--   2. project_task_defaults — per-project overrides (set at project creation or any time)
-- At task creation the application copies the resolved default into the task row
-- so historical costs are preserved even if defaults change later.

CREATE TABLE task_cost_defaults (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  task_type       task_type NOT NULL UNIQUE,          -- one global default per task type
  label           TEXT NOT NULL,                     -- human-readable name e.g. '2D Composite'
  default_cost    NUMERIC(15,4) NOT NULL,             -- cost per task in system base currency
  currency        currency_code NOT NULL DEFAULT 'USD',
  notes           TEXT,
  effective_from  DATE NOT NULL DEFAULT CURRENT_DATE,
  updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('task_cost_defaults');

-- Seed global defaults (edit these to match your studio's standard costs)
INSERT INTO task_cost_defaults (task_type, label, default_cost, currency) VALUES
  ('2d_comp',         '2D Composite',           2500.00, 'USD'),
  ('3d_comp',         '3D Composite',           3500.00, 'USD'),
  ('roto',            'Rotoscoping',             800.00, 'USD'),
  ('paint',           'Paint / Cleanup',         900.00, 'USD'),
  ('tracking',        'Tracking',                600.00, 'USD'),
  ('matchmove',       'Matchmove',              1200.00, 'USD'),
  ('fx_simulation',   'FX Simulation',          4500.00, 'USD'),
  ('lighting',        'Lighting',               4000.00, 'USD'),
  ('rendering',       'Rendering',              1500.00, 'USD'),
  ('modelling',       'Modelling',              3500.00, 'USD'),
  ('rigging',         'Rigging',                3000.00, 'USD'),
  ('animation',       'Animation',              4000.00, 'USD'),
  ('matte_painting',  'Matte Painting',         5000.00, 'USD'),
  ('colour_grade',    'Colour Grade',           1000.00, 'USD'),
  ('stereo_conversion','Stereo Conversion',     2000.00, 'USD'),
  ('previs',          'Previs',                 2500.00, 'USD'),
  ('techvis',         'Techvis',                2000.00, 'USD'),
  ('supervision',     'VFX Supervision',        8000.00, 'USD'),
  ('data_io',         'Data I/O',                400.00, 'USD'),
  ('other',           'Other',                  1000.00, 'USD');

-- ---------------------------------------------------------------------------
CREATE TABLE project_task_defaults (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  task_type       task_type NOT NULL,
  default_cost    NUMERIC(15,4) NOT NULL,             -- overrides global default for this project
  currency        currency_code NOT NULL,
  notes           TEXT,
  updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, task_type)
);
SELECT attach_updated_at('project_task_defaults');

CREATE INDEX idx_project_task_defaults_project ON project_task_defaults(project_id);



-- =============================================================================
-- SECTION 6: VENDORS
-- =============================================================================

CREATE TABLE vendors (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                TEXT NOT NULL,
  short_code          TEXT UNIQUE,                   -- e.g. 'MPC', 'DNEG', 'ILM'
  country_code        TEXT,                          -- ISO 3166-1 alpha-2
  default_currency    currency_code NOT NULL DEFAULT 'USD',

  -- Rebate / incentive details
  rebate_pct          NUMERIC(5,2) DEFAULT 0.00,     -- e.g. 32.00 for 32% rebate
  rebate_label        TEXT,                          -- e.g. 'UK HETV Incentive'
  rebate_notes        TEXT,

  -- Contacts
  primary_contact_name    TEXT,
  primary_contact_email   TEXT,
  bid_contact_email       TEXT,

  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  notes               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('vendors');

-- Exchange rates snapshot (updated per RFQ/bid)
CREATE TABLE exchange_rates (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_currency   currency_code NOT NULL,
  to_currency     currency_code NOT NULL,
  rate            NUMERIC(18,8) NOT NULL,
  source          TEXT DEFAULT 'manual',             -- 'manual' | 'openexchangerates'
  effective_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (from_currency, to_currency, effective_at)
);

CREATE INDEX idx_exchange_rates_lookup ON exchange_rates(from_currency, to_currency, effective_at DESC);


-- =============================================================================
-- SECTION 7: RFQ (REQUEST FOR QUOTE) & BIDDING
-- =============================================================================

CREATE TABLE rfqs (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  vendor_id           UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  rfq_number          TEXT NOT NULL,                 -- e.g. 'RFQ-001-MPC'
  status              rfq_status NOT NULL DEFAULT 'draft',

  -- Bid currency for this vendor
  bid_currency        currency_code NOT NULL,
  exchange_rate_id    UUID REFERENCES exchange_rates(id) ON DELETE SET NULL,
  exchange_rate_snapshot NUMERIC(18,8),              -- locked at time of issue

  -- Applied rebate (may differ from vendor default for this specific deal)
  rebate_pct          NUMERIC(5,2),

  -- Dates
  issued_date         DATE,
  due_date            DATE,
  received_date       DATE,

  -- Communication
  issued_by           UUID REFERENCES users(id) ON DELETE SET NULL,
  vendor_reference    TEXT,                          -- vendor's own reference number
  cover_letter        TEXT,
  notes               TEXT,

  -- Excel export tracking
  excel_exported_at   TIMESTAMPTZ,
  excel_path          TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, rfq_number)
);
SELECT attach_updated_at('rfqs');

CREATE INDEX idx_rfqs_project ON rfqs(project_id);
CREATE INDEX idx_rfqs_vendor ON rfqs(vendor_id);

-- ---------------------------------------------------------------------------
-- Which shots are included in a given RFQ
CREATE TABLE rfq_shots (
  rfq_id      UUID NOT NULL REFERENCES rfqs(id) ON DELETE CASCADE,
  shot_id     UUID NOT NULL REFERENCES shots(id) ON DELETE CASCADE,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (rfq_id, shot_id)
);

-- ---------------------------------------------------------------------------
-- Vendor bid (one per RFQ — a vendor can revise, tracked by version)
CREATE TABLE bids (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  rfq_id              UUID NOT NULL REFERENCES rfqs(id) ON DELETE CASCADE,
  vendor_id           UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  version             INTEGER NOT NULL DEFAULT 1,
  status              bid_status NOT NULL DEFAULT 'draft',

  -- Totals in vendor's currency (computed from line items but also storable directly)
  subtotal_vendor_currency    NUMERIC(15,4),
  rebate_amount_vendor_currency NUMERIC(15,4),
  total_vendor_currency       NUMERIC(15,4),

  -- Converted to project base currency
  subtotal_base_currency      NUMERIC(15,4),
  rebate_amount_base_currency NUMERIC(15,4),
  total_base_currency         NUMERIC(15,4),

  -- Excel import tracking
  excel_imported_at   TIMESTAMPTZ,
  excel_path          TEXT,

  notes               TEXT,
  submitted_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (rfq_id, version)
);
SELECT attach_updated_at('bids');

-- ---------------------------------------------------------------------------
-- Bid line items: vendor's cost per shot per task
CREATE TABLE bid_line_items (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  bid_id          UUID NOT NULL REFERENCES bids(id) ON DELETE CASCADE,
  shot_id         UUID NOT NULL REFERENCES shots(id) ON DELETE RESTRICT,
  task_type       task_type,                         -- NULL = overall shot cost (lump sum bid)
  description     TEXT,

  -- Vendor-quoted amounts (in RFQ currency)
  quoted_hours    NUMERIC(8,2),
  quoted_rate     NUMERIC(10,4),
  quoted_cost     NUMERIC(15,4) NOT NULL,

  -- Converted to project base currency at RFQ exchange rate
  cost_base_currency  NUMERIC(15,4),

  -- Vendor notes / qualifications
  vendor_notes    TEXT,
  is_excluded     BOOLEAN DEFAULT FALSE,             -- vendor explicitly excluded this item

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('bid_line_items');

CREATE INDEX idx_bid_line_items_bid ON bid_line_items(bid_id);
CREATE INDEX idx_bid_line_items_shot ON bid_line_items(shot_id);


-- =============================================================================
-- SECTION 8: BID COMPARISON & AWARD SCENARIOS
-- =============================================================================

-- A scenario is a named "what-if" allocation of shots to vendors for cost comparison
CREATE TABLE award_scenarios (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,                     -- e.g. 'Option A: Split MPC/DNEG'
  description     TEXT,
  is_selected     BOOLEAN NOT NULL DEFAULT FALSE,    -- the chosen scenario
  total_cost_base_currency NUMERIC(15,4),            -- computed aggregate
  created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('award_scenarios');

-- Each row = one shot assigned to one vendor in this scenario
CREATE TABLE award_scenario_items (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  scenario_id     UUID NOT NULL REFERENCES award_scenarios(id) ON DELETE CASCADE,
  shot_id         UUID NOT NULL REFERENCES shots(id) ON DELETE CASCADE,
  bid_id          UUID REFERENCES bids(id) ON DELETE SET NULL,       -- which bid line drives this
  bid_line_item_id UUID REFERENCES bid_line_items(id) ON DELETE SET NULL,
  vendor_id       UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  cost_vendor_currency  NUMERIC(15,4),
  cost_base_currency    NUMERIC(15,4),
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (scenario_id, shot_id)
);

CREATE INDEX idx_scenario_items_scenario ON award_scenario_items(scenario_id);


-- =============================================================================
-- SECTION 9: AWARDS & CONTRACTS
-- =============================================================================

CREATE TABLE awards (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  vendor_id           UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  scenario_id         UUID REFERENCES award_scenarios(id) ON DELETE SET NULL,
  bid_id              UUID REFERENCES bids(id) ON DELETE SET NULL,

  award_number        TEXT NOT NULL,                 -- e.g. 'AWD-001'
  awarded_date        DATE NOT NULL DEFAULT CURRENT_DATE,
  awarded_by          UUID REFERENCES users(id) ON DELETE SET NULL,

  -- Financial summary (in vendor currency & base currency)
  award_currency      currency_code NOT NULL,
  exchange_rate       NUMERIC(18,8),
  base_amount         NUMERIC(15,4) NOT NULL,        -- original awarded total in base currency
  vendor_amount       NUMERIC(15,4) NOT NULL,        -- original awarded total in vendor currency
  rebate_pct          NUMERIC(5,2) DEFAULT 0.00,
  rebate_amount_base  NUMERIC(15,4),
  net_base_amount     NUMERIC(15,4),                 -- base_amount - rebate

  -- Running totals (updated as change orders are approved)
  current_base_amount NUMERIC(15,4),                 -- base + all approved COs
  current_vendor_amount NUMERIC(15,4),

  po_number           TEXT,                          -- purchase order reference
  contract_path       TEXT,                          -- storage path to signed contract
  notes               TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (project_id, award_number)
);
SELECT attach_updated_at('awards');

CREATE INDEX idx_awards_project ON awards(project_id);
CREATE INDEX idx_awards_vendor ON awards(vendor_id);

-- ---------------------------------------------------------------------------
-- Awarded shots: which shots fall under each award
CREATE TABLE awarded_shots (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  award_id    UUID NOT NULL REFERENCES awards(id) ON DELETE CASCADE,
  shot_id     UUID NOT NULL REFERENCES shots(id) ON DELETE RESTRICT,
  awarded_cost_vendor_currency  NUMERIC(15,4) NOT NULL,
  awarded_cost_base_currency    NUMERIC(15,4) NOT NULL,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (award_id, shot_id)
);


-- =============================================================================
-- SECTION 10: CHANGE ORDERS
-- =============================================================================

CREATE TABLE change_orders (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  award_id            UUID NOT NULL REFERENCES awards(id) ON DELETE RESTRICT,
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  vendor_id           UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,

  co_number           TEXT NOT NULL,                 -- e.g. 'CO-001', 'CO-002'
  status              change_order_status NOT NULL DEFAULT 'draft',
  description         TEXT NOT NULL,
  reason              TEXT,                          -- creative change | technical add | omit

  -- Cost delta
  delta_vendor_currency   NUMERIC(15,4) NOT NULL,    -- positive = increase, negative = decrease
  delta_base_currency     NUMERIC(15,4) NOT NULL,
  exchange_rate           NUMERIC(18,8),

  -- Approvals
  requested_by        UUID REFERENCES users(id) ON DELETE SET NULL,
  requested_at        TIMESTAMPTZ,
  approved_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_at         TIMESTAMPTZ,
  rejected_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  rejected_at         TIMESTAMPTZ,
  rejection_reason    TEXT,

  -- Reference docs
  vendor_co_reference TEXT,
  document_path       TEXT,
  notes               TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (award_id, co_number)
);
SELECT attach_updated_at('change_orders');

CREATE INDEX idx_change_orders_award ON change_orders(award_id);
CREATE INDEX idx_change_orders_project ON change_orders(project_id);

-- ---------------------------------------------------------------------------
-- Which shots are affected by a change order
CREATE TABLE change_order_shots (
  change_order_id UUID NOT NULL REFERENCES change_orders(id) ON DELETE CASCADE,
  shot_id         UUID NOT NULL REFERENCES shots(id) ON DELETE RESTRICT,
  delta_vendor_currency NUMERIC(15,4),
  delta_base_currency   NUMERIC(15,4),
  is_new_shot     BOOLEAN DEFAULT FALSE,             -- shot added by this CO
  is_omitted_shot BOOLEAN DEFAULT FALSE,             -- shot removed by this CO
  notes           TEXT,
  PRIMARY KEY (change_order_id, shot_id)
);


-- =============================================================================
-- SECTION 11: AUTODESK FLOW / SHOTGRID SYNC
-- =============================================================================

CREATE TABLE flow_sync_log (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  entity_type     TEXT NOT NULL,                     -- 'shot' | 'asset' | 'task'
  local_id        UUID NOT NULL,
  flow_id         TEXT NOT NULL,
  direction       TEXT NOT NULL,                     -- 'push' | 'pull'
  status          TEXT NOT NULL,                     -- 'success' | 'error' | 'conflict'
  payload         JSONB,                             -- full sync payload for debugging
  error_message   TEXT,
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_flow_sync_entity ON flow_sync_log(entity_type, local_id);
CREATE INDEX idx_flow_sync_project ON flow_sync_log(project_id, synced_at DESC);

-- Conflict resolution queue
CREATE TABLE flow_sync_conflicts (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sync_log_id     UUID REFERENCES flow_sync_log(id) ON DELETE CASCADE,
  entity_type     TEXT NOT NULL,
  local_id        UUID NOT NULL,
  flow_id         TEXT,
  local_value     JSONB,
  flow_value      JSONB,
  resolved        BOOLEAN NOT NULL DEFAULT FALSE,
  resolution      TEXT,                              -- 'use_local' | 'use_flow' | 'merged'
  resolved_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  resolved_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =============================================================================
-- SECTION 12: EXCEL EXPORT / IMPORT TRACKING
-- =============================================================================

CREATE TABLE excel_exports (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  rfq_id          UUID REFERENCES rfqs(id) ON DELETE SET NULL,
  export_type     TEXT NOT NULL,                     -- 'bid_package' | 'cost_report' | 'comparison'
  file_path       TEXT NOT NULL,
  file_name       TEXT NOT NULL,
  exported_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  shot_count      INTEGER,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE excel_imports (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  rfq_id          UUID REFERENCES rfqs(id) ON DELETE SET NULL,
  bid_id          UUID REFERENCES bids(id) ON DELETE SET NULL,
  import_type     TEXT NOT NULL,                     -- 'vendor_bid' | 'script_breakdown'
  file_path       TEXT NOT NULL,
  file_name       TEXT NOT NULL,
  imported_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  rows_processed  INTEGER,
  rows_errored    INTEGER DEFAULT 0,
  errors          JSONB,                             -- array of {row, message}
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =============================================================================
-- SECTION 13: FINANCIAL REPORTS & SNAPSHOTS
-- =============================================================================

-- Snapshots: point-in-time financial state for trend reporting
CREATE TABLE financial_snapshots (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id              UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  snapshot_date           DATE NOT NULL DEFAULT CURRENT_DATE,
  approved_budget         NUMERIC(15,4),
  total_internal_estimate NUMERIC(15,4),             -- sum of all task estimated_cost
  total_awarded_base      NUMERIC(15,4),             -- sum of all awards net of rebate
  total_cos_approved      NUMERIC(15,4),             -- sum of approved change order deltas
  total_current_commitment NUMERIC(15,4),            -- awarded + approved COs
  total_actual_invoiced   NUMERIC(15,4),             -- invoices received to date
  variance_to_budget      NUMERIC(15,4),             -- budget - current_commitment
  shot_count_total        INTEGER,
  shot_count_approved     INTEGER,
  shot_count_delivered    INTEGER,
  notes                   TEXT,
  created_by              UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_snapshots_project_date ON financial_snapshots(project_id, snapshot_date DESC);

-- ---------------------------------------------------------------------------
CREATE TABLE reports (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  report_type     report_type NOT NULL,
  title           TEXT NOT NULL,
  generated_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  parameters      JSONB,                             -- report filter params
  output_path     TEXT,                              -- PDF/Excel output path
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Invoice tracking (for actuals)
CREATE TABLE invoices (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  award_id            UUID NOT NULL REFERENCES awards(id) ON DELETE RESTRICT,
  vendor_id           UUID NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

  invoice_number      TEXT NOT NULL,
  invoice_date        DATE NOT NULL,
  received_date       DATE,
  due_date            DATE,
  paid_date           DATE,

  amount_vendor_currency  NUMERIC(15,4) NOT NULL,
  amount_base_currency    NUMERIC(15,4),
  exchange_rate           NUMERIC(18,8),

  is_paid             BOOLEAN DEFAULT FALSE,
  document_path       TEXT,
  notes               TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT attach_updated_at('invoices');

CREATE INDEX idx_invoices_award ON invoices(award_id);
CREATE INDEX idx_invoices_project ON invoices(project_id);


-- =============================================================================
-- SECTION 14: AUDIT LOG
-- =============================================================================

CREATE TABLE audit_log (
  id          BIGSERIAL PRIMARY KEY,
  table_name  TEXT NOT NULL,
  record_id   UUID NOT NULL,
  action      TEXT NOT NULL,                         -- 'INSERT' | 'UPDATE' | 'DELETE'
  changed_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  old_data    JSONB,
  new_data    JSONB
);

CREATE INDEX idx_audit_record ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_changed_at ON audit_log(changed_at DESC);

-- Generic audit trigger function
CREATE OR REPLACE FUNCTION audit_trigger_fn()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
  VALUES (
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id),
    TG_OP,
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE row_to_json(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE row_to_json(NEW) END
  );
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Attach audit to financially sensitive tables
CREATE TRIGGER audit_awards
  AFTER INSERT OR UPDATE OR DELETE ON awards
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_change_orders
  AFTER INSERT OR UPDATE OR DELETE ON change_orders
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_bids
  AFTER INSERT OR UPDATE OR DELETE ON bids
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_bid_line_items
  AFTER INSERT OR UPDATE OR DELETE ON bid_line_items
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();


-- =============================================================================
-- SECTION 15: USEFUL VIEWS
-- =============================================================================

-- Project cost summary rollup
CREATE VIEW v_project_cost_summary AS
SELECT
  p.id                        AS project_id,
  p.title,
  p.approved_budget,
  p.base_currency,

  -- Internal estimate
  COALESCE(SUM(t.estimated_cost), 0)
                              AS total_internal_estimate,

  -- Awarded (gross, before rebate)
  COALESCE(SUM(DISTINCT a.base_amount), 0)
                              AS total_awarded_gross,

  -- Rebate
  COALESCE(SUM(DISTINCT a.rebate_amount_base), 0)
                              AS total_rebate,

  -- Net awarded
  COALESCE(SUM(DISTINCT a.net_base_amount), 0)
                              AS total_awarded_net,

  -- Approved change orders
  COALESCE((
    SELECT SUM(co.delta_base_currency)
    FROM change_orders co
    WHERE co.project_id = p.id AND co.status = 'approved'
  ), 0)                       AS total_co_approved,

  -- Total commitment
  COALESCE(SUM(DISTINCT a.net_base_amount), 0) +
  COALESCE((
    SELECT SUM(co.delta_base_currency)
    FROM change_orders co
    WHERE co.project_id = p.id AND co.status = 'approved'
  ), 0)                       AS total_current_commitment,

  -- Invoiced to date
  COALESCE((
    SELECT SUM(inv.amount_base_currency)
    FROM invoices inv
    WHERE inv.project_id = p.id
  ), 0)                       AS total_invoiced

FROM projects p
LEFT JOIN shots sh         ON sh.project_id = p.id AND sh.deleted_at IS NULL
LEFT JOIN tasks t          ON t.shot_id = sh.id
LEFT JOIN awards a         ON a.project_id = p.id
WHERE p.deleted_at IS NULL
GROUP BY p.id;

-- ---------------------------------------------------------------------------
-- Shot-level cost view (Updated for Multi-Vendor)
CREATE VIEW v_shot_costs AS
SELECT
  sh.id                       AS shot_id,
  sh.project_id,
  sh.shot_code,
  sh.status,

  -- Internal estimate
  COALESCE((SELECT SUM(t.estimated_cost) FROM tasks t WHERE t.shot_id = sh.id), 0) AS estimated_cost,

  -- Awarded cost (Summed across ALL vendors working on this shot)
  COALESCE((SELECT SUM(aw_sh.awarded_cost_base_currency) FROM awarded_shots aw_sh WHERE aw_sh.shot_id = sh.id), 0) AS awarded_cost_base,

  -- Change orders affecting this shot
  COALESCE((
    SELECT SUM(cos.delta_base_currency)
    FROM change_order_shots cos
    JOIN change_orders co ON co.id = cos.change_order_id
    WHERE cos.shot_id = sh.id AND co.status = 'approved'
  ), 0)                               AS co_delta_base,

  -- Current total
  COALESCE((SELECT SUM(aw_sh.awarded_cost_base_currency) FROM awarded_shots aw_sh WHERE aw_sh.shot_id = sh.id), 0) +
  COALESCE((
    SELECT SUM(cos.delta_base_currency)
    FROM change_order_shots cos
    JOIN change_orders co ON co.id = cos.change_order_id
    WHERE cos.shot_id = sh.id AND co.status = 'approved'
  ), 0)                               AS current_cost_base

FROM shots sh
WHERE sh.deleted_at IS NULL;
GROUP BY sh.id, sh.project_id, sh.shot_code, sh.status,
         sh.awarded_vendor_id, aw_sh.awarded_cost_base_currency;

-- ---------------------------------------------------------------------------
-- Bid comparison view (all bids for a project's shots side-by-side)
CREATE VIEW v_bid_comparison AS
SELECT
  sh.shot_code,
  sh.description              AS shot_description,
  v.name                      AS vendor_name,
  v.short_code                AS vendor_code,
  b.version                   AS bid_version,
  b.status                    AS bid_status,
  bli.task_type,
  bli.quoted_cost,
  rfq.bid_currency,
  bli.cost_base_currency,
  rfq.rebate_pct,
  bli.cost_base_currency * (1 - COALESCE(rfq.rebate_pct, 0) / 100.0)
                              AS net_cost_after_rebate,
  b.submitted_at
FROM bid_line_items bli
JOIN bids b           ON b.id = bli.bid_id
JOIN rfqs rfq         ON rfq.id = b.rfq_id
JOIN shots sh         ON sh.id = bli.shot_id
JOIN vendors v        ON v.id = b.vendor_id
WHERE b.status NOT IN ('withdrawn', 'rejected');


-- =============================================================================
-- SECTION 16: NOTES ON SEED DATA
-- =============================================================================
-- Global task cost defaults are seeded in Section 5 above (task_cost_defaults table).
-- Per-project overrides are added to project_task_defaults when a project is created.
-- At task creation the application should:
--   1. Look up project_task_defaults for this project + task_type
--   2. Fall back to task_cost_defaults if no project override exists
--   3. Write both values into tasks.project_default_cost and tasks.global_default_cost
--   4. Leave tasks.task_cost_override NULL unless the user explicitly overrides it
-- The generated column tasks.estimated_cost resolves: override ?? project ?? global


-- =============================================================================
-- SECTION 17: ROW LEVEL SECURITY (RLS) ENABLEMENT
-- =============================================================================

-- Enable RLS on core project tables
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE shots ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE bids ENABLE ROW LEVEL SECURITY;
ALTER TABLE awards ENABLE ROW LEVEL SECURITY;

-- Important: Enable RLS on your custom users table
ALTER TABLE users ENABLE ROW LEVEL SECURITY;


-- =============================================================================
-- SECTION 18: AUTHENTICATION TRIGGERS
-- =============================================================================

-- Create a function to handle new user signups
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.users (id, email, full_name, role)
  VALUES (
    new.id,
    new.email,
    -- Default the name to the email prefix if no name is provided during signup
    COALESCE(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    'coordinator' -- Default role
  );
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger this function every time a user is created in Supabase Auth
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();


-- =============================================================================
-- SECTION 19: RLS POLICIES (Simple Authentication Model)
-- =============================================================================

-- Allow users to read all other users (useful for assigning tasks, producers, etc.)
CREATE POLICY "Allow authenticated read on users" ON users
  FOR SELECT TO authenticated USING (true);

-- Allow users to update their own profile
CREATE POLICY "Allow user to update own profile" ON users
  FOR UPDATE TO authenticated USING (auth.uid() = id);

-- Universal Read/Write policies for authenticated users on core tables
-- (Note: For a small team, this assumes all logged-in users are trusted)

-- Projects
CREATE POLICY "Allow authenticated read on projects" ON projects FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on projects" ON projects FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on projects" ON projects FOR UPDATE TO authenticated USING (true);

-- Shots
CREATE POLICY "Allow authenticated read on shots" ON shots FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on shots" ON shots FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on shots" ON shots FOR UPDATE TO authenticated USING (true);
CREATE POLICY "Allow authenticated delete on shots" ON shots FOR DELETE TO authenticated USING (true);

-- Tasks
CREATE POLICY "Allow authenticated read on tasks" ON tasks FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on tasks" ON tasks FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on tasks" ON tasks FOR UPDATE TO authenticated USING (true);
CREATE POLICY "Allow authenticated delete on tasks" ON tasks FOR DELETE TO authenticated USING (true);

-- Vendors
CREATE POLICY "Allow authenticated read on vendors" ON vendors FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on vendors" ON vendors FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on vendors" ON vendors FOR UPDATE TO authenticated USING (true);

-- Bids
CREATE POLICY "Allow authenticated read on bids" ON bids FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on bids" ON bids FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on bids" ON bids FOR UPDATE TO authenticated USING (true);

-- Awards
CREATE POLICY "Allow authenticated read on awards" ON awards FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on awards" ON awards FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on awards" ON awards FOR UPDATE TO authenticated USING (true);


-- =============================================================================
-- END OF SCHEMA
-- =============================================================================

-- Quick sanity check query (run after migration):
-- SELECT table_name, pg_size_pretty(pg_total_relation_size(quote_ident(table_name)))
-- FROM information_schema.tables
-- WHERE table_schema = 'public'
-- ORDER BY pg_total_relation_size(quote_ident(table_name)) DESC;

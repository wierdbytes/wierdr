-- D1 schema of the relay (docs/relay.md). Applied with `bun run schema`; safe to run again.

-- App Attest keys the relay has seen attested: the public key it checks assertions
-- with, its environment (development: App Attest's sandbox; production: TestFlight, the
-- App Store and Xcode's exports), the build's category and version, Apple's receipt (for
-- the fraud metric, later) and the last assertion's counter. `owner` (96 bits of the
-- key id's SHA-256) is what grants name; a revoked key's grants stop working.
CREATE TABLE IF NOT EXISTS attest_keys (
  key_id TEXT PRIMARY KEY,      -- base64 of the key identifier (SHA-256 of the public key)
  owner TEXT NOT NULL UNIQUE,
  public_key TEXT NOT NULL,     -- base64 SubjectPublicKeyInfo (P-256)
  env TEXT NOT NULL,
  category INTEGER,             -- apple_validation_category_01 (iOS 27), if any
  bundle_version TEXT,
  receipt TEXT,                 -- base64
  counter INTEGER NOT NULL,
  created INTEGER NOT NULL,     -- unix seconds
  used INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0
);

-- Tokens each key got grants for (hashed): a key gets grants for a few tokens, not any.
CREATE TABLE IF NOT EXISTS device_tokens (
  owner TEXT NOT NULL,
  token TEXT NOT NULL,          -- base64url SHA-256 of the token
  env TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (owner, token, env)
);

-- Every channel the relay made: APNs keeps at most 10,000 per app and environment, and
-- a channel lives until it's deleted. Quotas count here; the hourly cron deletes ones
-- older than their grant.
CREATE TABLE IF NOT EXISTS channels (
  id TEXT NOT NULL,
  env TEXT NOT NULL,
  owner TEXT NOT NULL,
  created INTEGER NOT NULL,
  deleted INTEGER,              -- when, or NULL while it lives
  PRIMARY KEY (id, env)
);
CREATE INDEX IF NOT EXISTS channels_owner ON channels (owner, created);
CREATE INDEX IF NOT EXISTS channels_live ON channels (env, deleted, created);

-- The APNs provider token of the current 30-minute window and key, shared by every
-- isolate (APNs refuses one renewed more often than every 20 minutes).
CREATE TABLE IF NOT EXISTS apns_jwt (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  kid TEXT NOT NULL,
  iat INTEGER NOT NULL,
  token TEXT NOT NULL
);

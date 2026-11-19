-- D1 schema of the relay (docs/relay.md). Applied with `bun run schema`; safe to run again.

-- App Attest keys the relay has seen attested: the public key it checks assertions
-- with, its environment (development: a development-signed build, sandbox tokens;
-- production: TestFlight and the App Store) and the last assertion's counter.
CREATE TABLE IF NOT EXISTS attest_keys (
  key_id TEXT PRIMARY KEY,      -- base64 of the key identifier (SHA-256 of the public key)
  public_key TEXT NOT NULL,     -- base64 SubjectPublicKeyInfo (P-256)
  env TEXT NOT NULL,
  counter INTEGER NOT NULL,
  created INTEGER NOT NULL,     -- unix seconds
  used INTEGER NOT NULL
);

-- Channels made per device a day (a device's hashed token), so no one fills the app's
-- channels.
CREATE TABLE IF NOT EXISTS channel_quota (
  device TEXT NOT NULL,
  day INTEGER NOT NULL,         -- unix days
  n INTEGER NOT NULL,
  PRIMARY KEY (device, day)
);

-- The APNs provider token of the current 30-minute window, shared by every isolate
-- (APNs refuses one renewed more often than every 20 minutes).
CREATE TABLE IF NOT EXISTS apns_jwt (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  iat INTEGER NOT NULL,
  token TEXT NOT NULL
);

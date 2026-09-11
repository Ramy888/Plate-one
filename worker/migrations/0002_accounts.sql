-- Sign-in.
--
-- A device row now belongs to an account when one signed in. The column holds
-- a SHA-256 of the Google subject, never the subject itself and never an email
-- or a name: the app needs to know that two devices are the same person, and
-- nothing more than that. A hash answers that question and answers no others.
ALTER TABLE devices ADD COLUMN account_hash TEXT;
CREATE INDEX IF NOT EXISTS devices_account ON devices(account_hash);

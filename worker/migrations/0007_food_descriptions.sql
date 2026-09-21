-- Foods the catalogue does not contain, described in the engine's own terms.
--
-- Somebody says "pancakes". The catalogue has no pancake, so the plate came
-- back empty and the app asked what was in it — which made it look like it had
-- never heard of breakfast. The engine never needed the name though: it reasons
-- over protein, fibre and fat plus a few tags. So an unknown food only has to
-- be *described* in that vocabulary to be treated exactly like a catalogue one.
--
-- Cached by name so the second sighting is the first one's answer. That is what
-- keeps "the same plate gives the same options" true once a model is involved.
CREATE TABLE IF NOT EXISTS food_descriptions (
  name_key    TEXT PRIMARY KEY,   -- lower-cased, trimmed
  name        TEXT NOT NULL,      -- what the picture may call it
  protein     INTEGER NOT NULL,
  fibre       INTEGER NOT NULL,
  fat         INTEGER NOT NULL,
  tags        TEXT NOT NULL,      -- comma separated, from a fixed vocabulary
  food_group  TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);

-- Redeemed promo codes.
--
-- The codes themselves are never here: they live in a secret, because this
-- repository is public and a list of codes in it is a list of free credits.
-- What is stored is a hash of the code and who spent it, which is all that is
-- needed to stop it being spent twice.
CREATE TABLE IF NOT EXISTS promo_redemptions (
  code_hash   TEXT NOT NULL,
  redeemer    TEXT NOT NULL,          -- account hash when signed in, else device id
  redeemed_at INTEGER NOT NULL,
  PRIMARY KEY (code_hash, redeemer)
);
CREATE INDEX IF NOT EXISTS promo_by_code ON promo_redemptions(code_hash);

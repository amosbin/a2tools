-- schema.sql

BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS domains (
  domain TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK(status IN ('free','owned','taken','unavailable')),
  registrar TEXT DEFAULT NULL,
  dns_init INTEGER DEFAULT NULL,
  cert_date TEXT DEFAULT NULL
);
COMMIT;

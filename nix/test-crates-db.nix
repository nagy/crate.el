# test-crates-db.nix — fixture SQLite database for crate.el tests.
#
# Schema mirrors the real crates-io.db produced by the crates.io
# dumps (STRICT tables, WITHOUT ROWID on the primary key).  Tests
# point `crate-data-path' at this file instead of the real database
# so they never touch the network or the user's data.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

pkgs.runCommandLocal "test-crates.db"
  {
    nativeBuildInputs = [ pkgs.sqlite ];
  }
  ''
    sqlite3 $out <<'SQLEOF'
    CREATE TABLE crates (
      name TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      description TEXT,
      documentation TEXT,
      homepage TEXT,
      repository TEXT,
      created_at TEXT,
      updated_at TEXT,
      latest_version TEXT,
      license TEXT,
      downloads INTEGER NOT NULL DEFAULT 0,
      trustpub_only INTEGER NOT NULL DEFAULT 0
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE dependencies (
      id INTEGER PRIMARY KEY,
      crate_name TEXT NOT NULL,
      dep_name TEXT NOT NULL,
      req TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'normal',
      optional INTEGER NOT NULL DEFAULT 0
    ) STRICT;

    INSERT INTO crates VALUES ('serde','serde',
      'A generic serialization/deserialization framework',
      'https://docs.rs/serde',
      'https://serde.rs',
      'https://github.com/serde-rs/serde',
      '2020-01-09 20:22:35.387945+00',
      '2026-06-27 22:26:12.785151+00',
      '1.0.228',
      'MIT OR Apache-2.0',
      1131971135,
      0);

    INSERT INTO crates VALUES ('tokio','tokio',
      'An event-driven, non-blocking I/O platform for writing asynchronous I/O backed applications.',
      'https://docs.rs/tokio',
      NULL,
      'https://github.com/tokio-rs/tokio',
      '2016-09-27 20:50:13.879354+00',
      '2026-07-09 16:41:56.215247+00',
      '1.47.0',
      'MIT',
      500000000,
      0);

    INSERT INTO dependencies VALUES (1, 'serde', 'serde_core', '=1.0.228', 'normal', 0);
    INSERT INTO dependencies VALUES (2, 'serde', 'serde_derive', '^1', 'normal', 1);
    SQLEOF
  ''

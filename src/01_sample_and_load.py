#!/usr/bin/env python3
"""
Build data/kkbox.db from the extracted CSVs, filtered to the sampled subscribers.

Reads every source file in chunks so that nothing larger than a few hundred MB
is ever held in memory, filters each chunk to the 200k sampled subscribers, and
appends to SQLite. Dates stay as INTEGER YYYYMMDD, matching the source and
keeping the window joins in sql/02 index-friendly.

Usage, from the project root:

    python3 src/01_sample_and_load.py

Prerequisites:
    data/sample_msno.txt   written by notebooks/01_data_audit.ipynb
    data/logs_hist.csv     written by src/filter_logs.py
    data/*.csv             extracted by notebooks/01_data_audit.ipynb

Rebuilding is safe: existing tables are dropped and recreated.
"""

from pathlib import Path
import sqlite3
import sys
import time

import pandas as pd

PROJECT = Path(__file__).resolve().parent.parent
DATA = PROJECT / "data"
DB_PATH = DATA / "kkbox.db"
SAMPLE_FILE = DATA / "sample_msno.txt"

LOG_CHUNK = 2_000_000
TX_CHUNK = 1_000_000
MEMBER_CHUNK = 1_000_000


# ---------------------------------------------------------------------------
# Schema. This must match what sql/01-03 expect — do not edit one without
# the other.
# ---------------------------------------------------------------------------

SCHEMA = {
    "members": """
        CREATE TABLE members (
            msno              TEXT PRIMARY KEY,
            city              INTEGER,
            bd                INTEGER,
            age_stated        INTEGER,
            gender            TEXT,
            registered_via    INTEGER,
            registration_date INTEGER
        )
    """,
    "labels": """
        CREATE TABLE labels (
            msno     TEXT PRIMARY KEY,
            is_churn INTEGER NOT NULL
        )
    """,
    "transactions": """
        CREATE TABLE transactions (
            msno                   TEXT    NOT NULL,
            payment_method_id      INTEGER,
            payment_plan_days      INTEGER,
            plan_list_price        INTEGER,
            actual_amount_paid     INTEGER,
            is_auto_renew          INTEGER,
            transaction_date       INTEGER NOT NULL,
            membership_expire_date INTEGER,
            is_cancel              INTEGER,
            source_file            TEXT
        )
    """,
    "user_logs": """
        CREATE TABLE user_logs (
            msno        TEXT    NOT NULL,
            log_date    INTEGER NOT NULL,
            num_25      INTEGER,
            num_50      INTEGER,
            num_75      INTEGER,
            num_985     INTEGER,
            num_100     INTEGER,
            num_unq     INTEGER,
            total_secs  REAL,
            source_file TEXT
        )
    """,
}

INDEXES = [
    "CREATE INDEX idx_tx_msno_date   ON transactions (msno, transaction_date)",
    "CREATE INDEX idx_tx_expire      ON transactions (membership_expire_date)",
    "CREATE INDEX idx_logs_msno_date ON user_logs (msno, log_date)",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def fail(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(path):
    if not path.exists():
        fail(
            f"{path.relative_to(PROJECT)} not found.\n"
            "Run notebooks/01_data_audit.ipynb and src/filter_logs.py first, "
            "and start this from the project root."
        )
    return path


def load_chunked(conn, csv_path, table, keep, rename, dtypes, chunksize,
                 sample=None, prefilter=None):
    """Stream one CSV into a SQLite table, filtering to the sample as we go."""
    label = csv_path.name
    rows_in = rows_out = 0
    started = time.time()

    reader = pd.read_csv(
        csv_path,
        usecols=lambda c: c in keep,
        dtype=dtypes,
        chunksize=chunksize,
    )

    for chunk in reader:
        rows_in += len(chunk)

        if sample is not None:
            chunk = chunk[chunk["msno"].isin(sample)]

        if prefilter is not None and len(chunk):
            chunk = prefilter(chunk)

        if not len(chunk):
            continue

        chunk = chunk.rename(columns=rename)
        chunk["source_file"] = label if "source_file" in _columns(conn, table) else None
        if chunk["source_file"].isna().all():
            chunk = chunk.drop(columns=["source_file"])

        chunk.to_sql(table, conn, if_exists="append", index=False)
        rows_out += len(chunk)

        print(f"    {label:<24} {rows_in:>12,} read | {rows_out:>11,} kept", end="\r")

    mins = (time.time() - started) / 60
    print(f"    {label:<24} {rows_in:>12,} read | {rows_out:>11,} kept | {mins:.1f} min")
    return rows_in, rows_out


def _columns(conn, table):
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 74)
    print("Building kkbox.db")
    print("=" * 74)

    require(SAMPLE_FILE)
    sample = set(SAMPLE_FILE.read_text().split())
    print(f"\nsample: {len(sample):,} subscribers")

    for name in ["members_v3.csv", "train_v2.csv", "transactions.csv",
                 "transactions_v2.csv", "user_logs_v2.csv", "logs_hist.csv"]:
        require(DATA / name)

    if DB_PATH.exists():
        print(f"removing existing {DB_PATH.name}")
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)

    # Load-time only. These trade crash-safety for speed; the database is
    # rebuildable from the scripts, so the trade is free.
    conn.execute("PRAGMA journal_mode = OFF")
    conn.execute("PRAGMA synchronous  = OFF")
    conn.execute("PRAGMA cache_size   = -200000")
    conn.execute("PRAGMA temp_store   = MEMORY")

    for table, ddl in SCHEMA.items():
        conn.execute(ddl)
    conn.commit()
    print("schema created\n")

    # ---- labels -----------------------------------------------------------
    print("labels")
    load_chunked(
        conn, DATA / "train_v2.csv", "labels",
        keep={"msno", "is_churn"},
        rename={},
        dtypes={"msno": "string", "is_churn": "int8"},
        chunksize=MEMBER_CHUNK,
        sample=sample,
    )

    # ---- members ----------------------------------------------------------
    print("\nmembers")

    def add_age_stated(df):
        df = df.copy()
        df["age_stated"] = df["bd"].between(13, 100).astype("int8")
        return df

    load_chunked(
        conn, DATA / "members_v3.csv", "members",
        keep={"msno", "city", "bd", "gender", "registered_via",
              "registration_init_time"},
        rename={"registration_init_time": "registration_date"},
        dtypes={"msno": "string", "city": "Int16", "bd": "Int32",
                "gender": "string", "registered_via": "Int16",
                "registration_init_time": "Int32"},
        chunksize=MEMBER_CHUNK,
        sample=sample,
        prefilter=add_age_stated,
    )

    # ---- transactions -----------------------------------------------------
    print("\ntransactions  (two files, unioned)")
    tx_cols = {"msno", "payment_method_id", "payment_plan_days",
               "plan_list_price", "actual_amount_paid", "is_auto_renew",
               "transaction_date", "membership_expire_date", "is_cancel"}
    tx_dtypes = {
        "msno": "string", "payment_method_id": "Int16",
        "payment_plan_days": "Int16", "plan_list_price": "Int32",
        "actual_amount_paid": "Int32", "is_auto_renew": "Int8",
        "transaction_date": "Int32", "membership_expire_date": "Int32",
        "is_cancel": "Int8",
    }
    for name in ["transactions.csv", "transactions_v2.csv"]:
        load_chunked(conn, DATA / name, "transactions",
                     keep=tx_cols, rename={}, dtypes=tx_dtypes,
                     chunksize=TX_CHUNK, sample=sample)

    # ---- user logs --------------------------------------------------------
    print("\nuser_logs  (two files, unioned)")
    log_cols = {"msno", "date", "num_25", "num_50", "num_75", "num_985",
                "num_100", "num_unq", "total_secs"}
    log_dtypes = {
        "msno": "string", "date": "Int32",
        "num_25": "Int32", "num_50": "Int32", "num_75": "Int32",
        "num_985": "Int32", "num_100": "Int32", "num_unq": "Int32",
        "total_secs": "float64",
    }
    for name in ["logs_hist.csv", "user_logs_v2.csv"]:
        load_chunked(conn, DATA / name, "user_logs",
                     keep=log_cols, rename={"date": "log_date"},
                     dtypes=log_dtypes, chunksize=LOG_CHUNK, sample=sample)

    conn.commit()

    # ---- indexes ----------------------------------------------------------
    print("\nbuilding indexes (this takes a few minutes)")
    for stmt in INDEXES:
        started = time.time()
        conn.execute(stmt)
        name = stmt.split()[2]
        print(f"    {name:<22} {(time.time() - started) / 60:.1f} min")

    conn.execute("ANALYZE")
    conn.commit()

    validate(conn)

    conn.close()
    size_gb = DB_PATH.stat().st_size / 1e9
    print(f"\ndone. {DB_PATH.relative_to(PROJECT)} is {size_gb:.2f} GB")
    print("\nNext:")
    print("    sqlite3 data/kkbox.db < sql/01_clean_transactions.sql")


def validate(conn):
    print("\n" + "=" * 74)
    print("VALIDATION")
    print("=" * 74)

    print("\nrow counts")
    for table in SCHEMA:
        n = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        u = conn.execute(f"SELECT COUNT(DISTINCT msno) FROM {table}").fetchone()[0]
        print(f"    {table:<14} {n:>12,} rows | {u:>9,} subscribers")

    print("\nreferential integrity")
    checks = [
        ("labelled subscribers with no transaction",
         "SELECT COUNT(*) FROM labels l "
         "WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.msno = l.msno)"),
        ("labelled subscribers with no member record",
         "SELECT COUNT(*) FROM labels l "
         "WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.msno = l.msno)"),
        ("labelled subscribers with no listening log",
         "SELECT COUNT(*) FROM labels l "
         "WHERE NOT EXISTS (SELECT 1 FROM user_logs u WHERE u.msno = l.msno)"),
    ]
    for label, sql in checks:
        print(f"    {label:<45} {conn.execute(sql).fetchone()[0]:>9,}")

    print("\ndate coverage (confirms both source files landed)")
    for table, col in [("transactions", "transaction_date"), ("user_logs", "log_date")]:
        lo, hi = conn.execute(f"SELECT MIN({col}), MAX({col}) FROM {table}").fetchone()
        print(f"    {table:<14} {lo} -> {hi}")

    print("\nsource file split")
    for table in ["transactions", "user_logs"]:
        rows = conn.execute(
            f"SELECT source_file, COUNT(*) FROM {table} "
            "GROUP BY source_file ORDER BY source_file").fetchall()
        for src, n in rows:
            print(f"    {table:<14} {src:<22} {n:>12,}")

    print("\nknown dirty values (expected, handled downstream)")
    dirty = [
        ("negative total_secs", "SELECT COUNT(*) FROM user_logs WHERE total_secs < 0"),
        ("total_secs over 24h", "SELECT COUNT(*) FROM user_logs WHERE total_secs > 86400"),
        ("zero-price transactions", "SELECT COUNT(*) FROM transactions WHERE plan_list_price = 0"),
        ("paid above list price", "SELECT COUNT(*) FROM transactions "
                                  "WHERE actual_amount_paid > plan_list_price"),
        ("implausible age (bd)", "SELECT COUNT(*) FROM members WHERE age_stated = 0"),
    ]
    for label, sql in dirty:
        print(f"    {label:<45} {conn.execute(sql).fetchone()[0]:>9,}")

    churn = conn.execute("SELECT AVG(is_churn) FROM labels").fetchone()[0]
    print(f"\nsample churn rate: {churn:.4%}")
    print("Compare against the population figure from the audit notebook.")


if __name__ == "__main__":
    main()

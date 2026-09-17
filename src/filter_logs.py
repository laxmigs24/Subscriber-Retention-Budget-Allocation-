"""
Filter the KKBOX user_logs archive down to the sampled subscribers.

This script is not run directly. It reads from standard input, which means
7z streams the archive through it one line at a time and nothing larger than
a single row is ever held in memory or written to disk.

Usage, from the project root:

    7z e -so data/raw/user_logs.csv.7z | python3 src/filter_logs.py

Requires data/sample_msno.txt, written by notebooks/01_data_audit.ipynb.
Progress goes to stderr so it does not contaminate the data stream.
"""

import sys
import time
from pathlib import Path

KEEP_FILE = Path("data/sample_msno.txt")
OUT_FILE = Path("data/logs_hist.csv")
REPORT_EVERY = 5_000_000


def main() -> int:
    if not KEEP_FILE.exists():
        print(
            f"ERROR: {KEEP_FILE} not found.\n"
            "Run notebooks/01_data_audit.ipynb first, and start this from the project root.",
            file=sys.stderr,
        )
        return 1

    keep = set(KEEP_FILE.read_text().split())
    print(f"keeping {len(keep):,} subscribers", file=sys.stderr)

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    start = time.time()
    seen = kept = 0

    with OUT_FILE.open("w") as out:
        try:
            header = next(sys.stdin)
        except StopIteration:
            print("ERROR: no input received. Is the 7z command piping into this?", file=sys.stderr)
            return 1

        if not header.startswith("msno"):
            print(
                f"ERROR: unexpected first column. Got: {header[:80]!r}\n"
                "This script assumes msno is the first field.",
                file=sys.stderr,
            )
            return 1

        out.write(header)

        for line in sys.stdin:
            seen += 1
            if line.split(",", 1)[0] in keep:
                out.write(line)
                kept += 1
            if seen % REPORT_EVERY == 0:
                mins = (time.time() - start) / 60
                print(f"  {seen:>12,} read | {kept:>11,} kept | {mins:5.1f} min", file=sys.stderr)

    mins = (time.time() - start) / 60
    size_gb = OUT_FILE.stat().st_size / 1e9
    print(
        f"\ndone in {mins:.1f} min\n"
        f"  rows read : {seen:,}\n"
        f"  rows kept : {kept:,} ({kept / max(seen, 1):.2%})\n"
        f"  written   : {OUT_FILE} ({size_gb:.2f} GB)",
        file=sys.stderr,
    )

    if kept == 0:
        print("WARNING: nothing was kept. Check that sample_msno.txt matches this archive.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

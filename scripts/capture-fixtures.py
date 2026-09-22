#!/usr/bin/env python3
"""Capture real provider payloads as test fixtures.

The matcher is the component whose failure mode is the worst in the app — pricing
one race off another race's market — and it is currently tested only against
races that were invented to pass it. `docs/matching.md` says so under Known
limitations. What it needs is a **paired** capture: a Racing API card and the
Betfair catalogue for the same afternoon, taken minutes apart, so the two
providers' views of the same races can be joined for real.

That pairing is the whole point of this script. Capturing either side alone is
easy and proves nothing about the join.

Run it from the repo root with credentials in the environment:

    export RACING_USER=...  RACING_PASS=...
    export BF_APP_KEY=...   BF_USER=...  BF_PASS=...
    python3 scripts/capture-fixtures.py

Nothing is written until every file has been scanned for your credentials; see
"Redaction" below. Run with `--dry-run` first if you would rather look before
anything lands on disk.

Cannot be run from a Claude session: it needs live credentials, and both
providers sit outside that environment's network policy.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    print("This script needs Python 3.9 or newer (for zoneinfo).", file=sys.stderr)
    raise SystemExit(2)

# Racing days are Europe/London days. Same rule as RaceDates in the kit, and for
# the same reason: through BST a UTC day boundary puts an evening meeting on the
# wrong date.
LONDON = ZoneInfo("Europe/London")

RACING_BASE = "https://api.theracingapi.com"
BETFAIR_IDENTITY = "https://identitysso.betfair.com"
BETFAIR_BETTING = "https://api.betfair.com/exchange/betting/rest/v1.0"

# The Racing API free tier is 1 req/s. This is the floor, not a suggestion.
RACING_MIN_INTERVAL = 1.05

# listMarketBook refuses more than 40 market ids. A hard limit, not a guideline.
BETFAIR_BOOK_BATCH = 40

# Below this length a credential is too likely to collide with real data —
# a horse, a course, a trainer — to be safe to search for and replace.
MIN_SCANNABLE_SECRET = 8

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = REPO_ROOT / "ios/RacesKit/Tests/RacesKitTests/Fixtures"

# Daily captures accumulate into a corpus, not into the test bundle. A month of
# race days under `Fixtures/` would be copied into the test target by
# `.copy("Fixtures")` and bloat every `swift test` run; and committed fixtures
# are meant to be a handful of chosen payloads, not an archive.
DEFAULT_CORPUS = REPO_ROOT / "capture"

# `KEY=value` lines, so a daily run needs no exports. Gitignored.
CREDENTIALS_FILE = Path(__file__).resolve().parent / ".capture-env"

CREDENTIAL_NAMES = ("RACING_USER", "RACING_PASS", "BF_APP_KEY", "BF_USER", "BF_PASS")

# Keys whose values are secret wherever they appear, at any depth.
SECRET_KEYS = {
    "token",
    "sessiontoken",
    "password",
    "username",
    "appkey",
    "x-authentication",
    "x-application",
    "authorization",
}


_NORMALISED_SECRET_KEYS = {k.replace("_", "").replace("-", "") for k in SECRET_KEYS}


class CaptureError(RuntimeError):
    pass


# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------


def parse_env_file(text: str) -> dict[str, str]:
    """Parse `KEY=value` lines. Blank lines and `#` comments ignored.

    Deliberately not `source`-ing a shell file: this runs unattended from a
    scheduler, and a credentials file that can execute arbitrary code is a
    different risk from one that cannot.
    """
    values: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        # Tolerate quoting, since people will write it either way.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def load_credentials(path: Path = CREDENTIALS_FILE) -> None:
    """Fill missing credentials from the file. The environment always wins."""
    if not path.exists():
        return

    mode = path.stat().st_mode & 0o077
    if mode:
        print(
            f"Warning: {path} is readable by others (mode {oct(path.stat().st_mode & 0o777)}). "
            f"Run: chmod 600 {path}",
            file=sys.stderr,
        )

    for key, value in parse_env_file(path.read_text()).items():
        if key in CREDENTIAL_NAMES and not os.environ.get(key):
            os.environ[key] = value


# --------------------------------------------------------------------------
# Redaction
#
# Two independent passes, because either alone is easy to fool:
#
#   1. Key-based — anything under a key that names a secret is replaced, at any
#      depth, whatever its value.
#   2. Value-based — a literal scan for the actual secret strings taken from the
#      environment, plus the Betfair session token obtained during this run.
#
# The second is the one that actually guarantees anything. A provider that
# echoes your username back under a key nobody predicted is caught by it, and
# `verify_clean` then refuses to write the file at all if a secret survived.
# --------------------------------------------------------------------------


def redact(value: Any, secrets: list[str]) -> Any:
    """Recursively redact secret-named keys and secret-valued strings."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key.lower().replace("_", "").replace("-", "") in _NORMALISED_SECRET_KEYS:
                out[key] = "REDACTED"
            else:
                out[key] = redact(item, secrets)
        return out
    if isinstance(value, list):
        return [redact(item, secrets) for item in value]
    if isinstance(value, str):
        return scrub_string(value, secrets)
    return value


def scrub_string(text: str, secrets: list[str]) -> str:
    for secret in secrets:
        if secret and secret in text:
            text = text.replace(secret, "REDACTED")
    return text


def verify_clean(
    payload: Any, secrets: list[str], label: str, allow_opaque: bool = False
) -> None:
    """Refuse to write anything still containing a credential.

    Belt and braces after `redact`, and deliberately a separate step: a bug in
    the redactor should stop the commit, not silently ship a token.
    """
    blob = json.dumps(payload)
    for secret in secrets:
        if secret and secret in blob:
            raise CaptureError(
                f"{label}: a credential survived redaction. Nothing was written."
            )
    if allow_opaque:
        return
    # Betfair session tokens are long base64-ish runs. Catch one that arrived
    # under a key we did not anticipate. Reported in full rather than one at a
    # time, because a false positive here blocks the whole capture and the
    # person needs to see everything they are judging at once.
    opaque = sorted(set(re.findall(r"[A-Za-z0-9+/=]{40,}", blob)))
    if opaque:
        listing = "\n".join(f"    {run[:24]}… ({len(run)} chars)" for run in opaque[:10])
        raise CaptureError(
            f"{label}: {len(opaque)} opaque string(s) that could be a session token:\n"
            f"{listing}\n"
            "  Inspect them. If they are real data, re-run with --allow-opaque; "
            "if one is a credential, add its key to SECRET_KEYS. Nothing was written."
        )


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


def request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: float = 30.0,
) -> Any:
    request = urllib.request.Request(url, data=body, method=method)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:400]
        raise CaptureError(f"{method} {url} → HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise CaptureError(f"{method} {url} → {error.reason}") from error
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        head = raw[:200].decode("utf-8", "replace")
        raise CaptureError(
            f"{method} {url} → reply was not JSON ({len(raw)} bytes): {head!r}"
        ) from error


class RacingAPI:
    """The free tier, paced at 1 req/s."""

    def __init__(self, user: str, password: str) -> None:
        import base64

        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Accept": "application/json"}
        self._last_request = 0.0

    def get(self, path: str, params: list[tuple[str, str]] | None = None) -> Any:
        elapsed = time.monotonic() - self._last_request
        if elapsed < RACING_MIN_INTERVAL:
            time.sleep(RACING_MIN_INTERVAL - elapsed)
        self._last_request = time.monotonic()

        url = f"{RACING_BASE}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        return request_json(url, headers=self.headers)


class Betfair:
    def __init__(self, app_key: str, user: str, password: str) -> None:
        self.app_key = app_key
        self.user = user
        self.password = password
        self.token: str | None = None

    def log_in(self) -> str:
        body = urllib.parse.urlencode(
            {"username": self.user, "password": self.password}
        ).encode()
        # `+` is literal in a form body and decodes as a space. Betfair passwords
        # routinely contain one; urlencode handles it, but the app's HTTPClient
        # had to be taught the same lesson, so it is worth a note here too.
        reply = request_json(
            f"{BETFAIR_IDENTITY}/api/login",
            method="POST",
            headers={
                "X-Application": self.app_key,
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            body=body,
        )
        # Betfair reports failure with HTTP 200 and status FAIL. A status-code
        # check reads that as a success that happens to have no token.
        if reply.get("status") != "SUCCESS" or not reply.get("token"):
            raise CaptureError(
                "Betfair refused the login: "
                f"{reply.get('error') or reply.get('status') or 'no reason given'}"
            )
        self.token = reply["token"]
        return self.token

    def betting(self, endpoint: str, payload: dict) -> Any:
        if not self.token:
            raise CaptureError("betting call before login")
        reply = request_json(
            f"{BETFAIR_BETTING}/{endpoint}/",
            method="POST",
            headers={
                "X-Application": self.app_key,
                "X-Authentication": self.token,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            body=json.dumps(payload).encode(),
        )
        # A fault arrives on a 200 as readily as on a 400, and an unhandled one
        # decodes as an empty array — indistinguishable from "no racing today".
        if isinstance(reply, dict) and "detail" in reply:
            code = (
                reply.get("detail", {})
                .get("APINGException", {})
                .get("errorCode", "unknown")
            )
            raise CaptureError(f"{endpoint} returned fault {code}")
        return reply


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


# After this London hour the day's racing is over and starting prices have
# settled. Before it, markets are live and SP_TRADED has nothing to say.
SETTLED_AFTER_LONDON_HOUR = 20


def wants_settled_prices(london: dt.datetime, override: bool | None = None) -> bool:
    """Whether to ask Betfair for SP_TRADED.

    Decided from the clock rather than passed in, because `launchd` uses one
    argument list for every fire time — so a single agent could not ask for it
    on the late run and not on the afternoon one. The decision is printed.
    """
    if override is not None:
        return override
    return london.hour >= SETTLED_AFTER_LONDON_HOUR


def is_empty_payload(payload: Any) -> bool:
    """Whether there is nothing in here worth keeping.

    An evening catalogue after racing has finished is an empty list — a correct
    answer, and noise in a corpus. The count is still reported; only the file is
    skipped.
    """
    if isinstance(payload, list):
        return len(payload) == 0
    if isinstance(payload, dict):
        return len(payload) == 0
    return payload is None


def output_path(name: str, day: str, stamp: str, root: Path, as_fixture: bool) -> Path:
    """Where a captured payload goes.

    A fixture is dated and lands flat, matching the existing naming. A corpus
    entry is filed under its London day and carries the time, because a day
    needs **two** runs to be complete — one during racing for live prices and a
    full catalogue, one after it for results and settled SP — and neither may
    overwrite the other.
    """
    if as_fixture:
        return root / f"{name}-{day.replace('-', '')}.json"
    return root / day / f"{name}-{stamp}.json"


def london_day_bounds(when: dt.datetime) -> tuple[str, str]:
    """ISO-8601 start/end of `when`'s London day, in UTC as Betfair wants."""
    local = when.astimezone(LONDON)
    start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + dt.timedelta(days=1)
    to_utc = lambda d: d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return to_utc(start), to_utc(end)


def capture(args: argparse.Namespace) -> int:
    load_credentials()

    missing = [name for name in CREDENTIAL_NAMES if not os.environ.get(name)]
    if missing and not args.racing_only:
        print(
            f"Missing credentials: {', '.join(missing)}\n"
            f"Export them, or put KEY=value lines in {CREDENTIALS_FILE} (chmod 600).",
            file=sys.stderr,
        )
        return 2
    if args.racing_only and not os.environ.get("RACING_USER"):
        print("Missing RACING_USER / RACING_PASS", file=sys.stderr)
        return 2

    # Only long, distinctive credentials are scanned for as literal strings.
    # Usernames are not: they are short, and a username of "ben" would rewrite
    # every jockey called Benoit and then block the capture forever because the
    # "secret" genuinely appears in the data. Usernames are still redacted by
    # key name, which is where a provider would actually echo one.
    secrets = [
        value
        for name in ("RACING_PASS", "BF_APP_KEY", "BF_PASS")
        if len(value := os.environ.get(name, "")) >= MIN_SCANNABLE_SECRET
    ]
    short = [
        name
        for name in ("RACING_PASS", "BF_APP_KEY", "BF_PASS")
        if 0 < len(os.environ.get(name, "")) < MIN_SCANNABLE_SECRET
    ]
    if short:
        print(
            f"Note: {', '.join(short)} shorter than {MIN_SCANNABLE_SECRET} characters, "
            "so not scanned for as literal text (too likely to match real data). "
            "Key-based redaction still applies.",
            file=sys.stderr,
        )

    now = dt.datetime.now(dt.timezone.utc)
    london = now.astimezone(LONDON)
    day = london.strftime("%Y-%m-%d")
    stamp = london.strftime("%H%M%S")
    captures: dict[str, Any] = {}

    root = Path(args.out) if args.out else (FIXTURES_DIR if args.fixtures else DEFAULT_CORPUS)
    print(f"London day {day}, {stamp} — writing to {root}")

    # ---- Racing API -----------------------------------------------------
    racing = RacingAPI(os.environ["RACING_USER"], os.environ["RACING_PASS"])
    regions = [("region_codes", "gb"), ("region_codes", "ire")]

    print("Racing API: courses…")
    captures[f"racingapi-courses-{day}.json"] = racing.get("/v1/courses", regions)

    print("Racing API: today's card…")
    captures[f"racingapi-racecards-free-{day}.json"] = racing.get(
        "/v1/racecards/free", [("day", "today"), *regions]
    )

    print("Racing API: today's results…")
    captures[f"racingapi-results-today-free-{day}.json"] = racing.get(
        "/v1/results/today/free"
    )

    # ---- Betfair --------------------------------------------------------
    if not args.racing_only:
        print("Betfair: logging in…")
        betfair = Betfair(
            os.environ["BF_APP_KEY"], os.environ["BF_USER"], os.environ["BF_PASS"]
        )
        # The session token is a secret obtained *during* the run, so it joins
        # the redaction list the moment it exists.
        secrets.append(betfair.log_in())

        settled = wants_settled_prices(london, args.settled)
        print(
            f"Betfair: {'asking for settled SP' if settled else 'live prices only'} "
            f"({london:%H:%M} London)"
        )
        start, end = london_day_bounds(now)
        print(f"Betfair: catalogue for {start} → {end}…")
        catalogue = betfair.betting(
            "listMarketCatalogue",
            {
                "filter": {
                    "eventTypeIds": ["7"],
                    "marketCountries": ["GB", "IE"],
                    "marketTypeCodes": ["WIN"],
                    "marketStartTime": {"from": start, "to": end},
                },
                "marketProjection": [
                    "RUNNER_METADATA",
                    "MARKET_START_TIME",
                    "EVENT",
                ],
                "maxResults": args.max_markets,
                "sort": "FIRST_TO_START",
            },
        )
        captures[f"betfair-listmarketcatalogue-{day}.json"] = catalogue

        market_ids = [m["marketId"] for m in catalogue][:BETFAIR_BOOK_BATCH]
        if market_ids:
            print(f"Betfair: prices for {len(market_ids)} markets…")
            captures[f"betfair-listmarketbook-{day}.json"] = betfair.betting(
                "listMarketBook",
                {
                    "marketIds": market_ids,
                    "priceProjection": {
                        "priceData": ["EX_BEST_OFFERS", "EX_TRADED", "SP_AVAILABLE"]
                        + (["SP_TRADED"] if settled else []),
                        "virtualise": True,
                    },
                },
            )
        else:
            print("  (no markets in the window — nothing to price)")

    # ---- Redact, verify, write -----------------------------------------
    cleaned: dict[str, Any] = {}
    skipped: list[str] = []
    for name, payload in captures.items():
        if is_empty_payload(payload):
            # A correct answer, and noise in a corpus. Reported, not stored.
            skipped.append(name)
            continue
        scrubbed = redact(payload, secrets)
        verify_clean(scrubbed, secrets, name, allow_opaque=args.allow_opaque)
        cleaned[name] = scrubbed

    for name in skipped:
        print(f"  (empty, not written: {name})")

    if not cleaned:
        print("\nNothing to write. Every payload was empty.")
        return 0

    cleaned["capture-manifest"] = {
        "capturedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "londonDay": day,
        "londonTime": london.strftime("%H:%M:%S"),
        "files": sorted(cleaned),
        "emptyAndSkipped": sorted(skipped),
        "note": (
            "A London day needs two runs to be complete: one during racing for "
            "live prices and a full catalogue, one after it for results and "
            "settled SP. Neither overwrites the other."
        ),
    }

    paths = {
        name: output_path(name, day, stamp, root, as_fixture=args.fixtures)
        for name in cleaned
    }

    if args.dry_run:
        print("\n--dry-run: nothing written. Would have written:")
        for name in sorted(cleaned):
            size = len(json.dumps(cleaned[name]))
            count = len(cleaned[name]) if isinstance(cleaned[name], list) else "-"
            print(f"  {paths[name]}  ({size:,} bytes, {count} top-level items)")
        return 0

    for name in sorted(cleaned):
        path = paths[name]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(cleaned[name], indent=2, sort_keys=True) + "\n")
        print(f"  wrote {path}")

    if args.fixtures:
        print(
            "\nRead at least one file before committing. The redactor is careful "
            "and is not a substitute for looking."
        )
    return 0


def self_test() -> int:
    """Exercise the pure logic with no credentials and no network.

    The redactor is the only part of this script that can do real harm — a
    missed token committed to a repository — and it is also the only part
    checkable without live credentials. So it is checked here, and anyone can
    run it: `python3 scripts/capture-fixtures.py --self-test`.
    """
    failures: list[str] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        print(("  PASS  " if condition else "  FAIL  ") + name + (f"  {detail}" if not condition else ""))
        if not condition:
            failures.append(name)

    secret = "sup3rsecretpassword123"
    token = "AbCdEf0123456789" * 4  # 64 chars, shaped like a real session token

    # --- redaction ---
    nested = {"a": {"b": [{"sessionToken": token, "X-Authentication": token,
                           "app_key": "k", "horse": "Frankel"}]}}
    inner = redact(nested, [])["a"]["b"][0]
    check("key-based redaction reaches nested lists", inner["sessionToken"] == "REDACTED")
    check("kebab-case header key redacted", inner["X-Authentication"] == "REDACTED")
    check("snake_case app_key redacted", inner["app_key"] == "REDACTED")
    check("ordinary data untouched", inner["horse"] == "Frankel")

    sneaky = redact({"debugEcho": f"query was password={secret}"}, [secret])
    check("literal secret scrubbed under an unanticipated key",
          secret not in sneaky["debugEcho"])

    try:
        verify_clean({"leak": secret}, [secret], "t", allow_opaque=True)
        check("verify_clean blocks a surviving secret", False)
    except CaptureError:
        check("verify_clean blocks a surviving secret", True)

    try:
        verify_clean({"mystery": token}, [], "t")
        check("an opaque run blocks the write", False)
    except CaptureError as error:
        check("an opaque run blocks the write", "session token" in str(error))
    try:
        verify_clean({"mystery": token}, [], "t", allow_opaque=True)
        check("--allow-opaque lets it through", True)
    except CaptureError:
        check("--allow-opaque lets it through", False)

    realistic = {"marketId": "1.245678901", "runners": [{
        "selectionId": 12345678, "runnerName": "Kyprios (IRE)",
        "metadata": {"CLOTH_NUMBER": "3", "COLOURS_FILENAME": "c20240601abc.jpg",
                     "COLOURS_DESCRIPTION": "Royal blue, orange hoop, striped sleeves"}}]}
    try:
        verify_clean(realistic, [], "catalogue")
        check("realistic catalogue data does not trip the opaque check", True)
    except CaptureError as error:
        check("realistic catalogue data does not trip the opaque check", False, str(error)[:120])

    check("a short name survives scrubbing",
          redact({"jockey": "Benoit Le Moine"}, [])["jockey"] == "Benoit Le Moine")

    # --- London day bounds ---
    summer_start, summer_end = london_day_bounds(
        dt.datetime(2026, 7, 15, 12, 0, tzinfo=dt.timezone.utc))
    winter_start, _ = london_day_bounds(
        dt.datetime(2026, 12, 15, 12, 0, tzinfo=dt.timezone.utc))
    check("a BST day starts at 23:00Z the day before",
          summer_start == "2026-07-14T23:00:00Z", summer_start)
    check("a BST day ends at 23:00Z", summer_end == "2026-07-15T23:00:00Z", summer_end)
    check("a GMT day starts at 00:00Z",
          winter_start == "2026-12-15T00:00:00Z", winter_start)

    # --- credentials file ---
    parsed = parse_env_file(
        "# a comment\n\nRACING_USER=ben\n"
        'BF_PASS="quoted value"\n'
        "BF_APP_KEY = spaced \n"
        "NOT_A_PAIR\n")
    check("env file skips comments and blanks", "NOT_A_PAIR" not in parsed)
    check("env file reads a plain value", parsed.get("RACING_USER") == "ben", parsed)
    check("env file strips quotes", parsed.get("BF_PASS") == "quoted value", parsed)
    check("env file strips whitespace", parsed.get("BF_APP_KEY") == "spaced", parsed)

    # --- what is worth keeping ---
    check("an empty catalogue is not written", is_empty_payload([]))
    check("an empty object is not written", is_empty_payload({}))
    check("a populated list is written", not is_empty_payload([{"marketId": "1.1"}]))
    check("a zero-length string list is still a list", not is_empty_payload([""]))

    # --- when to ask for settled prices ---
    def at(hour):
        return dt.datetime(2026, 9, 22, hour, 0, tzinfo=LONDON)
    check("an afternoon run asks for live prices", not wants_settled_prices(at(15)))
    check("a late run asks for settled SP", wants_settled_prices(at(22)))
    check("the boundary hour counts as late", wants_settled_prices(at(20)))
    check("--settled forces it on early", wants_settled_prices(at(9), override=True))
    check("--no-settled forces it off late", not wants_settled_prices(at(23), override=False))

    # --- output paths ---
    corpus = output_path("racingapi-racecards-free", "2026-09-22", "134501",
                         Path("/tmp/c"), as_fixture=False)
    fixture = output_path("racingapi-racecards-free", "2026-09-22", "134501",
                          Path("/tmp/f"), as_fixture=True)
    check("a corpus entry is filed under its London day",
          str(corpus) == "/tmp/c/2026-09-22/racingapi-racecards-free-134501.json", str(corpus))
    check("a fixture keeps the flat dated name",
          str(fixture) == "/tmp/f/racingapi-racecards-free-20260922.json", str(fixture))
    # The whole point of the timestamp: two runs a day, neither overwriting the
    # other, because one gets prices and the other gets results.
    afternoon = output_path("x", "2026-09-22", "134501", Path("/tmp/c"), as_fixture=False)
    evening = output_path("x", "2026-09-22", "210233", Path("/tmp/c"), as_fixture=False)
    check("two runs on one day do not collide", afternoon != evening)
    check("both land in the same day folder", afternoon.parent == evening.parent)

    print()
    print("FAILED: " + ", ".join(failures) if failures else "all checks passed")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--out",
        default=None,
        help=f"explicit output directory (default: {DEFAULT_CORPUS})",
    )
    parser.add_argument(
        "--fixtures",
        action="store_true",
        help="write a dated committed fixture into the kit's Fixtures directory "
             "instead of into the corpus",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="check the redactor with no credentials and no network, then exit",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="fetch and redact, but write nothing",
    )
    parser.add_argument(
        "--racing-only",
        action="store_true",
        help="skip Betfair, for a Racing-API-only capture",
    )
    settled = parser.add_mutually_exclusive_group()
    settled.add_argument(
        "--settled",
        dest="settled",
        action="store_const",
        const=True,
        help=f"force asking for SP_TRADED (default: after {SETTLED_AFTER_LONDON_HOUR}:00 London)",
    )
    settled.add_argument(
        "--no-settled",
        dest="settled",
        action="store_const",
        const=False,
        help="force live prices only",
    )
    parser.set_defaults(settled=None)
    parser.add_argument(
        "--allow-opaque",
        action="store_true",
        help="proceed when long opaque strings are present and you have checked them",
    )
    parser.add_argument(
        "--max-markets",
        type=int,
        default=200,
        help="maxResults for listMarketCatalogue (default 200)",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    try:
        return capture(args)
    except CaptureError as error:
        print(f"\nCapture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

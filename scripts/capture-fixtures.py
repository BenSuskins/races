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
DEFAULT_OUT = REPO_ROOT / "ios/RacesKit/Tests/RacesKitTests/Fixtures"

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
# Capture
# --------------------------------------------------------------------------


def london_day_bounds(when: dt.datetime) -> tuple[str, str]:
    """ISO-8601 start/end of `when`'s London day, in UTC as Betfair wants."""
    local = when.astimezone(LONDON)
    start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + dt.timedelta(days=1)
    to_utc = lambda d: d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return to_utc(start), to_utc(end)


def capture(args: argparse.Namespace) -> int:
    missing = [
        name
        for name in ("RACING_USER", "RACING_PASS", "BF_APP_KEY", "BF_USER", "BF_PASS")
        if not os.environ.get(name)
    ]
    if missing and not args.racing_only:
        print(f"Missing environment variables: {', '.join(missing)}", file=sys.stderr)
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
    day = now.astimezone(LONDON).strftime("%Y%m%d")
    captures: dict[str, Any] = {}

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
                        + (["SP_TRADED"] if args.settled else []),
                        "virtualise": True,
                    },
                },
            )
        else:
            print("  (no markets in the window — nothing to price)")

    # ---- Redact, verify, write -----------------------------------------
    cleaned = {}
    for name, payload in captures.items():
        scrubbed = redact(payload, secrets)
        verify_clean(scrubbed, secrets, name, allow_opaque=args.allow_opaque)
        cleaned[name] = scrubbed

    manifest = {
        "capturedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "londonDay": now.astimezone(LONDON).strftime("%Y-%m-%d"),
        "files": sorted(cleaned),
        "note": (
            "Paired capture: the Racing API card and the Betfair catalogue were "
            "taken minutes apart on the same London day, so RaceMatcher can be "
            "tested against two real views of the same races."
        ),
    }
    cleaned[f"capture-manifest-{day}.json"] = manifest

    out = Path(args.out)
    if args.dry_run:
        print("\n--dry-run: nothing written. Would have written:")
        for name, payload in sorted(cleaned.items()):
            size = len(json.dumps(payload))
            count = len(payload) if isinstance(payload, list) else "-"
            print(f"  {out / name}  ({size:,} bytes, {count} top-level items)")
        return 0

    out.mkdir(parents=True, exist_ok=True)
    for name, payload in sorted(cleaned.items()):
        path = out / name
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"  wrote {path}")

    print(
        "\nRead at least one file before committing. The redactor is careful and "
        "is not a substitute for looking."
    )
    return 0


def self_test() -> int:
    """Exercise the redactor with no credentials and no network.

    The redactor is the only part of this script that can do real harm — a
    missed token is committed to a repository — and it is also the only part
    that can be checked without live credentials. So it is checked here, and
    anyone can run it: `python3 scripts/capture-fixtures.py --self-test`.
    """
    failures: list[str] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        print(("  PASS  " if condition else "  FAIL  ") + name + (f"  {detail}" if not condition else ""))
        if not condition:
            failures.append(name)

    secret = "sup3rsecretpassword123"
    token = "AbCdEf0123456789" * 4  # 64 chars, shaped like a real session token

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

    # Realistic catalogue data must not trip the opaque check, or the escape
    # hatch becomes mandatory and stops being a signal.
    realistic = {"marketId": "1.245678901", "runners": [{
        "selectionId": 12345678, "runnerName": "Kyprios (IRE)",
        "metadata": {"CLOTH_NUMBER": "3", "COLOURS_FILENAME": "c20240601abc.jpg",
                     "COLOURS_DESCRIPTION": "Royal blue, orange hoop, striped sleeves"}}]}
    try:
        verify_clean(realistic, [], "catalogue")
        check("realistic catalogue data does not trip the opaque check", True)
    except CaptureError as error:
        check("realistic catalogue data does not trip the opaque check", False, str(error)[:120])

    # The collision hazard: a short username scanned as a literal would rewrite
    # every jockey whose name contains it, and then block the capture forever
    # because the "secret" really is in the data.
    check("a short name survives scrubbing",
          redact({"jockey": "Benoit Le Moine"}, [])["jockey"] == "Benoit Le Moine")

    summer_start, summer_end = london_day_bounds(
        dt.datetime(2026, 7, 15, 12, 0, tzinfo=dt.timezone.utc))
    winter_start, _ = london_day_bounds(
        dt.datetime(2026, 12, 15, 12, 0, tzinfo=dt.timezone.utc))
    check("a BST day starts at 23:00Z the day before",
          summer_start == "2026-07-14T23:00:00Z", summer_start)
    check("a BST day ends at 23:00Z", summer_end == "2026-07-15T23:00:00Z", summer_end)
    check("a GMT day starts at 00:00Z",
          winter_start == "2026-12-15T00:00:00Z", winter_start)

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
        default=str(DEFAULT_OUT),
        help="where to write fixtures (default: the kit's Fixtures directory)",
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
        help="skip Betfair — useful while the login is still unresolved",
    )
    parser.add_argument(
        "--settled",
        action="store_true",
        help="also ask for SP_TRADED; only meaningful after racing has finished",
    )
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

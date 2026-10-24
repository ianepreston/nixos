#!/usr/bin/env python3
"""Normalize a Wealthsimple activities export into Wealthfolio's canonical CSV.

    wealthfolio-import export.csv [more.csv ...]

Each INPUT.csv is written to INPUT-parsed.csv beside it. Output columns are Wealthfolio's own import names, so the importer auto-maps
them and the activityType values need no per-account mapping. Output is
deterministic: Wealthfolio dedupes on (account, type, date, amounts, comment),
so re-importing an overlapping export is a no-op for rows already imported.
"""

import csv
import datetime as dt
import re
import sys
from decimal import Decimal
from pathlib import Path

# Ticker changes Wealthsimple records as LegacyCorporateAction/NAME_CHANGE.
# History is rewritten onto the new ticker and the paired rows are dropped.
RENAMES = {"PZD": "ERTH"}

# Wealthsimple symbol -> Wealthfolio symbol. Listing venue is not in the export,
# so every symbol must be listed; an unknown one is a hard error. A wrong venue
# is NOT flagged by Wealthfolio at import: the asset is created,
# its Yahoo quote 404s, and it silently values at zero (account valuation shows
# PARTIAL_UNPRICED). A bare ticker can also resolve to the wrong security:
# Yahoo's PSA is Public Storage, not Purpose's PSA.TO. Cboe Canada listings take
# .NE, not .TO; BMO's hedged ".F" units are Yahoo's "-F.NE".
SYMBOLS = {
    **{
        s: f"{s}.TO"
        for s in (
            "PSA",
            "XEN",
            "ZBI",
            "ZCS",
            "ZFH",
            "ZFL",
            "ZFM",
            "ZGB",
            "ZGLD",
            "ZMP",
            "ZST",
            "WSRD",
            "WSRI",
        )
    },
    **{s: f"{s}.NE" for s in ("QTIP", "WSGB")},
    **{f"{s}.F": f"{s}-F.NE" for s in ("ZAAA", "ZBBZ")},
    **{s: s for s in ("CLOZ", "CRBN", "ERTH", "GLDM", "VIDI")},  # US listings
}

EXECUTED = re.compile(r"executed at (\d{4}-\d{2}-\d{2})")
OUT = [
    "date",
    "account",
    "activityType",
    "subtype",
    "symbol",
    "quantity",
    "unitPrice",
    "currency",
    "fee",
    "amount",
    "comment",
]


def activity_date(r):
    # Date-only records are midnight Eastern rendered in Mountain time, so they
    # carry 22:00 on the previous day. Prefer the explicit execution date.
    if m := EXECUTED.search(r["description"]):
        return m[1]
    d = dt.date.fromisoformat(r["effective_date"])
    if r["effective_time"] == "22:00:00":
        d += dt.timedelta(days=1)
    return d.isoformat()


def dec(v):
    return Decimal(v) if v else Decimal(0)


def convert(r):
    """Return (type, subtype, use_asset) or None to drop the row."""
    t, sub = r["activity_type"], r["activity_sub_type"]
    net, qty = dec(r["net_cash_amount"]), dec(r["quantity"])
    match t, sub:
        case "Trade", "BUY" | "SELL":
            return sub, "", True
        case "Dividend", _:
            return "DIVIDEND", "", True
        case "Fee", _:
            return "FEE", "", False
        case "Tax", "NRT":
            return "TAX", "WITHHOLDING", False
        case "MoneyMovement", "EFT":
            return ("DEPOSIT" if net > 0 else "WITHDRAWAL"), "", False
        case "MoneyMovement", "TRANSFER" | "TRANSFER_TF":
            # Cash moved to/from another account. Wealthfolio's importer marks
            # these external (portfolio contribution/withdrawal) unless the raw
            # type says INTERNAL: right for the many whose other leg is an
            # account not in the export; a pair inside it nets to zero.
            return ("TRANSFER_IN" if net > 0 else "TRANSFER_OUT"), "", False
        case "Interest", _:
            return "INTEREST", "", False
        case "ReturnOfCapital" | "NonCashDistribution", _ if (
            "Adjusted Cost Base Entry Only" in r["description"]
        ):
            # Book-cost-only: no cash or units move. Wealthfolio has no ACB
            # adjustment yet; a plain ADJUSTMENT is a recorded no-op, so cost
            # basis drifts from Wealthsimple's by these amounts.
            return "ADJUSTMENT", "", True
        case "InternalSecurityTransfer", _:
            return ("TRANSFER_IN" if qty > 0 else "TRANSFER_OUT"), "", True
        case "AdministrativePayment", "MANAGEMENT_FEE_REFUND":
            # A negative refund is the refund being clawed back.
            return ("CREDIT", "REFUND", False) if net > 0 else ("FEE", "", False)
        case "Correction", _:
            # Symbol-less cash fix; ADJUSTMENT would require an asset.
            return ("CREDIT", "", False) if net > 0 else ("FEE", "", False)
        case "LegacyCorporateAction", "NAME_CHANGE" if (
            r["symbol"] in RENAMES.values() | RENAMES.keys()
        ):
            return None
        case "LegacyCorporateAction", "NAME_CHANGE":
            # Quantity correction (e.g. GLDM 2022): holdings-only, no cash.
            return ("TRANSFER_IN" if qty > 0 else "TRANSFER_OUT"), "", True
    raise SystemExit(f"unmapped Wealthsimple type {t}/{sub}: {r['description']}")


def rows(path):
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if not r.get("effective_date"):  # trailing "As of ..." footer
                continue
            if (conv := convert(r)) is None:
                continue
            kind, subtype, use_asset = conv
            net, qty = dec(r["net_cash_amount"]), dec(r["quantity"])
            sym = RENAMES.get(r["symbol"], r["symbol"])
            out = {
                "date": activity_date(r),
                "account": r["account_id"],
                "activityType": kind,
                "subtype": subtype,
                "currency": r["currency"] or "CAD",
                "comment": r["description"],
                "fee": r["commission"] or "",
                "amount": abs(net) if r["net_cash_amount"] else "",
            }
            if use_asset:
                if sym not in SYMBOLS:
                    raise SystemExit(
                        f"unmapped symbol {sym}: add its Yahoo listing to SYMBOLS"
                    )
                out["symbol"] = SYMBOLS[sym]
            if kind == "ADJUSTMENT":
                out["amount"] = ""
            # A dividend's "quantity" in the export is its cash amount, and an
            # ADJUSTMENT's is its book-cost change.
            if use_asset and kind not in ("DIVIDEND", "ADJUSTMENT"):
                out["quantity"] = abs(qty)
                price = r["unit_price"]
                if not price and net and qty:
                    price = abs(net / qty).quantize(Decimal("0.000001"))
                out["unitPrice"] = price
            yield out


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: wealthfolio-import <export.csv> [more.csv ...]")
    for src in map(Path, sys.argv[1:]):
        # Convert fully before opening the output so an unmapped type leaves
        # no partial file behind.
        out = sorted(rows(src), key=lambda o: (o["account"], o["date"]))
        dest = src.with_name(f"{src.stem}-parsed.csv")
        with open(dest, "w", newline="") as f:
            w = csv.DictWriter(f, OUT, lineterminator="\n")
            w.writeheader()
            w.writerows(out)
        print(f"{src} -> {dest} ({len(out)} activities)")


if __name__ == "__main__":
    main()

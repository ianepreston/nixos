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

# Wealthsimple symbol -> Wealthfolio symbol. Listing venue is not in the export;
# anything absent is passed through bare (US listing). Extend as new
# holdings appear; the preview step flags any symbol it can't resolve.
SYMBOLS = {
    s: f"{s}.TO"
    for s in ("XEN", "ZFL", "ZFM", "ZMP", "ZGB", "ZGLD", "QTIP", "WSGB", "WSRD", "WSRI")
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
        case "MoneyMovement", "TRANSFER_TF":
            # Cash moved between Wealthsimple accounts, not an external flow.
            return ("TRANSFER_IN" if net > 0 else "TRANSFER_OUT"), "", False
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
                out["symbol"] = SYMBOLS.get(sym, sym)
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

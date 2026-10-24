#!/usr/bin/env python3
"""Convert a Wealthsimple activities export for Wealthfolio and for acb.

    wealthsimple-convert export.csv [more.csv ...]

Each INPUT.csv is written beside it as:

- INPUT-parsed.csv: Wealthfolio's canonical import CSV. Its column names are
  Wealthfolio's own, so the importer auto-maps them and the activityType values
  need no per-account mapping. Trade prices are backed out of the cash charged
  (see trade_price). Output is deterministic: Wealthfolio dedupes on
  (account, type, date, amounts, comment), so re-importing an overlapping
  export is a no-op for rows already imported.
- INPUT-acb.csv: transactions for the acb ACB calculator. It is built from the
  export directly, not via Wealthfolio, because Wealthfolio cannot hold the
  ACB-only return-of-capital / reinvested-distribution entries acb needs.
  Export every account together: acb must see all of a security's history.
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


def trade_price(r):
    # Wealthsimple rounds a trade's cash to the cent but reports the unrounded
    # execution price. Wealthfolio and acb both book quantity x price + fee, so
    # the export's price drifts cash and cost by a fraction of a cent per trade.
    # Back the price out of the cash actually charged instead.
    net, qty, fee = dec(r["net_cash_amount"]), dec(r["quantity"]), dec(r["commission"])
    gross = abs(net) - fee if r["activity_sub_type"] == "BUY" else abs(net) + fee
    return (gross / abs(qty)).quantize(Decimal("1e-10"))


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
                if r["activity_type"] == "Trade":
                    price = trade_price(r)
                elif not price and net and qty:
                    price = abs(net / qty).quantize(Decimal("0.000001"))
                out["unitPrice"] = price
            yield out


# acb (tsiemens/acb) affiliates are per taxpayer, not per account: ACB pools
# across every non-registered account holding the same security, and the
# registered ones exist only so acb can catch superficial losses against them.
REGISTERED = {"TFSA", "RRSP", "FHSA", "RESP", "RRIF", "LIRA", "LIF", "RDSP"}
ACB_OUT = [
    "security",
    "trade date",
    "settlement date",
    "action",
    "shares",
    "amount/share",
    "total amount",
    "currency",
    "commission",
    "affiliate",
    "memo",
]


def affiliate(r):
    if r["account_type"] == "Non-registered":
        return "Default"
    if r["account_type"] in REGISTERED:
        return "Default (R)"
    raise SystemExit(f"unknown account type {r['account_type']!r}: {r['account_id']}")


def acb_rows(path):
    """Share-moving and ACB-moving rows only; cash-only activity has no ACB."""
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if not r.get("effective_date"):
                continue
            t, sub = r["activity_type"], r["activity_sub_type"]
            net, qty = dec(r["net_cash_amount"]), dec(r["quantity"])
            date = activity_date(r)
            out = {
                "security": RENAMES.get(r["symbol"], r["symbol"]),
                "trade date": date,
                "settlement date": r["settlement_date"] or date,
                "currency": r["currency"] or "CAD",
                "affiliate": affiliate(r),
                "memo": r["description"],
            }
            match t, sub:
                case "Trade", "BUY" | "SELL":
                    out |= {
                        "action": sub.capitalize(),
                        "shares": abs(qty),
                        "amount/share": trade_price(r),
                        "commission": r["commission"] or "0",
                    }
                case "InternalSecurityTransfer", _:
                    # Shares crossing the export boundary. The other leg is an
                    # account not in the export, so model it as a disposition /
                    # acquisition at the transfer value. Right for a move into a
                    # registered account (a deemed disposition); between your
                    # own non-registered accounts ACB carries over instead, so
                    # check these by hand.
                    out |= {
                        "action": "Buy" if qty > 0 else "Sell",
                        "shares": abs(qty),
                        "amount/share": abs(net / qty).quantize(Decimal("0.000001")),
                        "commission": "0",
                        "memo": f"TRANSFER, verify treatment: {r['description']}",
                    }
                case "ReturnOfCapital", _ if net < 0:
                    out |= {"action": "RoC", "total amount": -net}
                case "NonCashDistribution", _ if net > 0:
                    # Reinvested capital-gains distribution: ACB up, no units.
                    out |= {"action": "RiCGDist", "total amount": net}
                case "ReturnOfCapital" | "NonCashDistribution", _:
                    raise SystemExit(f"unexpected sign on {t}: {r['description']}")
                case "LegacyCorporateAction", "NAME_CHANGE" if (
                    r["symbol"] in RENAMES.values() | RENAMES.keys()
                ):
                    continue
                case "LegacyCorporateAction", "NAME_CHANGE":
                    if out["affiliate"] == "Default":
                        # A share-count fix with no price would corrupt ACB.
                        raise SystemExit(
                            f"non-registered correction: {r['description']}"
                        )
                    out |= {
                        "action": "Buy" if qty > 0 else "Sell",
                        "shares": abs(qty),
                        "amount/share": "0",
                        "commission": "0",
                    }
                case _:
                    # Every other type is cash-only. convert() is the
                    # exhaustive check, run first, so nothing unknown gets here.
                    continue
            yield out


def write_csv(dest, fields, rows):
    with open(dest, "w", newline="") as f:
        w = csv.DictWriter(f, fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: wealthsimple-convert <export.csv> [more.csv ...]")
    for src in map(Path, sys.argv[1:]):
        # Convert fully before opening any output so an unmapped type leaves
        # no partial file behind.
        wf = sorted(rows(src), key=lambda o: (o["account"], o["date"]))
        acb = sorted(acb_rows(src), key=lambda o: (o["security"], o["trade date"]))
        parsed = src.with_name(f"{src.stem}-parsed.csv")
        acb_dest = src.with_name(f"{src.stem}-acb.csv")
        write_csv(parsed, OUT, wf)
        write_csv(acb_dest, ACB_OUT, acb)
        print(f"{src} -> {parsed} ({len(wf)} activities)")
        print(f"{src} -> {acb_dest} ({len(acb)} acb transactions)")


if __name__ == "__main__":
    main()

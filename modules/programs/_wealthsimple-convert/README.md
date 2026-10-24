# Wealthsimple and Shareworks imports

`wealthsimple-convert` turns a brokerage activity export into two deterministic
CSV files beside the source file:

- `INPUT-parsed.csv` is Wealthfolio's generic-import format.
- `INPUT-acb.csv` is input for [acb][acb], the Canadian adjusted-cost-base
  calculator served at `acb.ipreston.net`.

The original export is evidence. Keep it outside this public repository: it
contains financial transactions and personal account information.

## Databricks RSUs (Shareworks)

Use the **all-time Transaction History CSV** in Shareworks / Morgan Stanley at
Work. In the Activity or Transactions view, set the date range to include every
release and sale, then use the page's Download/Export CSV control. The parser
identifies that report by its `Date`, `Type`, `Plan`, `Quantity`, `Price`, `Tax
Payment Method`, `Net Share Proceeds`, and `Net Cash Proceeds` columns. It
skips any title/footer lines in the report.

Do not use the portfolio/holdings snapshot: it has today's position but cannot
reconstruct the ACB. Also save each release confirmation and sale confirmation
PDF for your records. They are not parser input, but are the source to resolve
an exception if the CSV's transaction history does not reconcile.

Run:

```sh
wealthsimple-convert shareworks-transaction-history.csv
```

The defaults name the Wealthfolio account `Databricks RSU` and use the private,
manual symbol `DATABRICKS-RSU`. Do not use `DBX`: it is Dropbox's public ticker,
not Databricks. Change either only if the first Wealthfolio import shows a
different account name or the plan covers another issuer:

```sh
wealthsimple-convert \
  --shareworks-account 'Databricks RSU' \
  --shareworks-symbol DATABRICKS-RSU \
  shareworks-transaction-history.csv
```

For a `Withhold to Cover` release, the outputs acquire the net delivered shares
at the release price. That is equivalent to acquiring the gross vested shares
and immediately disposing of the withheld shares at the same price, while
avoiding a synthetic tax sale. A normal `Sale` becomes a sale with its
commission derived from gross less net proceeds. An unfamiliar transaction type
is an error, not a silently incomplete import.

Import `*-parsed.csv` through Wealthfolio's generic CSV importer. Before
filing, import the matching `*-acb.csv` through ACB's CSV import at
`acb.ipreston.net`; it needs the complete Databricks position to calculate
gains and superficial losses.

At Wealthfolio's asset-review step, create `DATABRICKS-RSU` as a custom USD
investment asset. In its Market Data settings, turn automatic updates off and
add a manual quote dated at the newest vest with its Shareworks release price.
That is the latest known private-company valuation; update the quote only when
Databricks publishes a newer authoritative value (for example, a 409A, tender,
or financing valuation).

The generated ACB rows are USD because Shareworks records the release and sale
prices in USD. `acb` converts them at the Bank of Canada rate for the trade date.
This is an input to tax preparation, not tax advice.

## Workday reconciliation

No Workday export is required to replay holdings. Download the pay-slip PDFs
covering every RSU vest from Workday's Pay / Payslips page, and retain the T4
for the year. The T4 alone is not granular enough to set a per-vest ACB. Use
the pay slip's equity/stock-compensation taxable benefit to reconcile each
Shareworks release confirmation:

```text
Workday CAD taxable benefit ≈ gross vested shares × Shareworks USD release price × FX
```

If payroll used an FX rate that differs from `acb`'s Bank of Canada rate,
enter that rate in the blank `exchange rate` cell on the corresponding **Buy**
row in `*-acb.csv` before running `acb`. Compute it as:

```text
Workday CAD taxable benefit / (gross vested shares × Shareworks USD release price)
```

Use gross vested shares for this check, not Shareworks' `Net Share Proceeds`.
Keep the Workday PDFs and release confirmations private; do not add them, a
de-identified extract, or their values to git or a public pull request.

## Wealthsimple

For Wealthsimple, export the all-time account Activities CSV and run the same
command. The parser already handles the date and activity-code defects in
Wealthsimple's built-in Wealthfolio template, and writes the matching ACB file.

[acb]: https://github.com/tsiemens/acb

# Money Ledger

An automatic expense and income ledger for India. It reads bank and UPI transaction
alerts on your phone, works out what each one was, and keeps a running ledger —
without you typing anything.

**Your messages never leave your device.** Parsing, categorization and storage all
happen locally. This repository is public so that claim can be checked rather than
trusted.

---

## How it works

```
                        YOUR PHONE
                             |
        SMS receiver  +  notification listener  (native Kotlin)
                             |
                     trust gate — is this sender a real bank?
                     (TRAI DLT header allowlist; OTPs and
                      promos are dropped before parsing)
                             |
                     parser — amount, direction, date,
                     account tail, merchant, reference
                             |
                     categorizer — cheap checks first:
                       merchant dictionary
                       -> UPI VPA heuristics
                       -> channel signals (ATM/POS/NACH)
                       -> your own learned rules
                       -> ask you, once, and remember
                             |
                     local encrypted database
                             |
             ledger · bills · budgets · reports · CSV export


                        THE SERVER
          knows nothing about you, holds no account,
          stores no transaction, has no write endpoint.
          It serves three static files:

            GET /v1/manifest        what changed
            GET /v1/categories      the taxonomy
            GET /v1/merchants       merchant -> category
            GET /v1/parser-rules    bank SMS templates
```

The server exists for one reason: bank SMS formats change without warning. Keeping
the parsing rules as **data** rather than compiled code means a broken bank format
is fixed in minutes for everyone, instead of waiting on an app store release.

## Design decisions

These are deliberate and load-bearing. Changing any of them changes what this app is.

| Decision | Why |
|---|---|
| **Everything on-device** | The app's whole premise. It is also what makes the Google Play SMS permission declaration defensible — Play policy forbids budgeting apps from exfiltrating message data. |
| **No login, no account** | You open the app and see your ledger. No email, no OTP, no signup wall. Backup is a local encrypted export you control. |
| **Server is read-only** | No write endpoints, no auth, no database. There is nothing to breach because there is nothing there. |
| **Unknown merchants ask you** | A bare UPI VPA like `paytmqr2810...@paytm` is genuinely unidentifiable. It goes to an Uncategorized queue; one tap teaches a permanent rule. Nothing is sent anywhere to find out. |
| **Two ingestion paths** | Notification listening works with no restricted permissions. SMS access additionally unlocks importing your history. The app is fully functional either way. |
| **Transfers are not spending** | Moving money between your own accounts, paying a credit card bill, withdrawing cash, topping up a wallet — none of these are expenses. Counting them is why other trackers show inflated totals. |

## Repository layout

```
app/      Flutter application
          lib/          Dart — ledger, categorizer, UI
          android/      Kotlin — SMS receiver, notification listener
server/   FastAPI config server (deployed to Railway)
rules/    Shared source of truth — parser templates, merchant
          dictionary, category taxonomy. Bundled into the app at
          build time and served by the server for live updates.
```

`rules/` is shared deliberately: the app ships with a copy so it works offline from
first launch, and pulls updates when the server has a newer version.

## Development

Requires Flutter 3.47+ and Python 3.12+.

```bash
cd app && flutter pub get && flutter run
```

```bash
pip install -r requirements.txt && uvicorn server.main:app --reload
```

Railway deploys from the repository root (not `server/`), because the server reads
`rules/` at startup.

## Status

Early. Scaffolding and the rules schema are in place; the parser corpus, the
categorization engine and the ledger core are being built. The parser templates in
`rules/parser_rules.json` are seeds and are not yet validated against a real message
corpus.

## Privacy

No analytics. No advertising identifiers. No crash reporting that includes message
content. No network request carries a transaction, a merchant name, an account
number or a phone number. The server never learns that you exist.

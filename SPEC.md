# SMS-Driven Expense & Income Ledger for India — Build Specification

**Status:** implementation-ready draft, v1.0
**Date:** 2026-09-23
**Audience:** the solo developer (or an agent) building this from zero, with `digikavach-v2-app` available as a donor codebase.
**Authority note:** where this document states a Google Play policy position, it reflects an adversarial verification pass that re-read the live policy pages. Claims that could not be verified are labelled **[UNVERIFIED]**. Do not "improve" a labelled claim into a confident one without re-checking the source.

---

## 1. Verdict

**It can be built, and the Play-policy path is real — but the fallback architecture most developers reach for is itself a violation, and that is the single most important sentence here.**

Lead with the policy reality, because it determines the architecture:

1. **The exception you need exists and is alive.** Google Play's SMS and Call Log policy lists **"SMS-based money management"** as a permitted use case with the example *"apps that track and manage budget"*, covering exactly `READ_SMS`, `RECEIVE_MMS`, `RECEIVE_SMS`, `RECEIVE_WAP_PUSH`. Verified present on the live policy page (support.google.com/googleplay/android-developer/answer/10208820) as of 2026-09-23, **and** carried unchanged into the preview policy effective **27 January 2027** (answer/17225965). This is not a loophole you are hoping survives; it is a named row with your app's exact description in it.

2. **There is no organizational-account bar for this declaration.** No policy text in 10208820, 9214102 or 16558241 imposes a developer-account-type requirement, and the governing sentence is that Google reviews requests and grants exceptions **case-by-case**. Multiple bank-SMS-reading expense trackers from small/individual developers are live in India today (Track My Spend, Vrid, FinArt, Mera Kharcha, alongside moneyview and axio). The "solo devs can't get READ_SMS" belief is refuted by existence proof.

3. **The real, documented failure mode is your store listing, not your code.** Policy 10208820 requires that your description *prominently documents and promotes* the core feature. An app whose listing talks about "smart budgeting" while the declaration claims SMS reading is core is the one genuinely documented way to fail. Write the listing before you file the declaration.

4. **The fallback you were going to build is banned.** Google's Permissions and APIs that Access Sensitive Information policy states you may not use alternative methods — including other permissions, APIs, or third-party sources — to derive data attributed to Call Log or SMS related permissions (answer/16558241, carried into preview 16909972). A `NotificationListenerService` that scrapes bank/UPI notifications to build the same ledger **is** deriving SMS-attributed data. It is not a safe harbour; it is a different violation, and a worse-shaped one, because there is no declaration form for notification access — so you get **no review signal at all**, and your first feedback is a post-publication enforcement action with one appeal. DigiKavach's `ScamNotificationListener` is excellent engineering and you should steal its threading, but **it must not be the ledger's ingestion fallback.**

5. **The honest risks, ranked without false precision.** There is no published approval rate, no rejection-reason breakdown, and no evidence of a 2025–26 mass-rejection wave against SMS budgeting apps (I looked; there isn't one in either direction). So nobody — including this document — can tell you your odds. What is certain: the review may take *several weeks* with no SLA, and if you are on a **personal** Play account you must first run closed testing with **12 testers opted in continuously for 14 days** before production (answer/13634885); organization accounts are exempt. That 14-day gate runs *in front of* the multi-week permission review. Budget six to eight calendar weeks of pure waiting before v1 can be public, and do not let it block development.

6. **The engineering risk is larger than the policy risk, and it is not where you think.** DigiKavach's SMS receiver is dead code — correct, complete, and never registered. There is no classifier, no transaction parser, no Room database, and no inbox backfill anywhere in the donor repo. You are inheriting *plumbing*, not *intelligence*. Roughly 35–40% of the work is already paid for, and it is the unglamorous 35–40%.

7. **The product risk is the biggest of the three.** A fraud scanner can be wrong 5% of the time and still be useful. A ledger that is wrong 5% of the time is worse than no ledger, because the user loses the ability to tell which 5%. Every design decision below follows from that: **silent-and-confident is strictly worse than unparsed-and-visible.**

**Build it. Register as an organization if you can. Ship the SMS path as the only automated path. Make the no-SMS mode genuinely non-derivative — manual entry, share-to-app, CSV/statement import — not a notification listener wearing a different hat.**

---

## 2. What already exists in DigiKavach, and what must be built new

Donor repo: `C:\Users\reddy\Downloads\digikavach-v2-app` (also the Desktop working copy). Paths below are repo-relative.

### 2.1 Lift verbatim (or near-verbatim)

| File | Why | Change needed |
|---|---|---|
| `core/auth/SessionCrypto.kt` (64 lines) | AES-256/GCM, AndroidKeyStore alias, 12-byte IV, 128-bit tag, `Base64(IV‖ct)`. Works. Drops straight into a Room `SupportFactory` passphrase wrapper or field-level encryption. | Rename the key alias. Add an explicit "key missing → surface an error, do not return empty" path (see §2.3). |
| `core/detection/LocalMessageCheck.kt` line 7 — the normaliser | NFKC + zero-width/bidi strip. Bank SMS carry odd Unicode; this is the de-obfuscation you need before any regex. | Extract the normaliser into `SmsNormalizer`; drop the three scam regexes. |
| `service/SmsScanReceiver.kt` lines 33, 43, 74–76 | The `goAsync()` → `CoroutineScope(SupervisorJob() + Dispatchers.IO)` → `pending.finish()` in `finally` bridge. Textbook-correct and the single most copyable thing in the file. | Delete the premium gate at line 46 (see traps). Replace the Retrofit call with the local pipeline. |
| `service/ScamNotificationListener.kt` — the work queue | Bounded `Channel<Unit>(64)`, exactly 2 drain coroutines, per-key in-flight dedup via `ConcurrentHashMap<String, Job>` with `job.join()`, and `@Synchronized updateEligibility()` that cancels all jobs and drains the channel when the data owner/consent changes. Best-engineered code in the repo. | Reuse the *skeleton* for the SMS ingest queue. Do **not** reuse the listener itself as an ingestion source (§9). |
| `kavach/ui/components/Charts.kt` (248 lines) | `ScoreRing`→category donut, `ScoreTrendChart`→monthly spend trend, `SparkLine`→per-category mini-trend, `BrandMeter`→budget-vs-actual. Four composables, label changes only. | Retheme tokens. |
| `kavach/ui/components/Common.kt` (846 lines), `ScreenScaffold.kt`, `BottomBar.kt`, `Dialogs.kt` | The shared widget library and page shell. | Retheme. |
| `core/ui/theme/` — `KavachColors.kt`, `Theme.kt`, `ScoreState.kt` | The `compositionLocalOf` (not `static`) decision at `Theme.kt:14–23` is load-bearing if you animate a colour band. `ScoreTheme` bands → budget-health bands with near-zero change. | Rename tokens. |
| `core/ui/SecureScreen.kt` | `FLAG_SECURE`. A ledger showing bank balances wants this **on by default**. | Make it a user-visible setting, default ON. |
| `app/build.gradle.kts:43–62` — the signing config | Reads git-ignored `keystore.properties`; if absent, **creates no signingConfig at all** so the release is unsigned by design rather than silently debug-signed. Copy verbatim, including the comment. | New keystore, stored outside the repo. |
| `app/build.gradle.kts:96–100` — test input wiring | Declares `src/main/res` as a Test input with RELATIVE path sensitivity so a string change doesn't report UP-TO-DATE and silently disable the locale guard. | Keep if you ship translations (and this time, actually ship them — see traps). |
| `MainActivity.kt` ~199–213 — `grantJustArrived()` | Auto-enables a guard on the permission-arrival *transition*, not the state. The state-based version made it impossible to turn a guard off. | Keep the transition semantics. |
| Hilt graph, `AuthInterceptors` shape, permission-setup flow (`feature/permissions/PermissionSetupScreen.kt`), onboarding, splash | Months of unglamorous work. | Strip the backend coupling. |

### 2.2 Recover from git (do not rewrite from memory)

The manifest registration deleted at commit `d90e7ff`. Recover with `git show d90e7ff^:app/src/main/AndroidManifest.xml` (lines 57–65):

```xml
<receiver android:name=".service.SmsReceiver" android:exported="true"
          android:permission="android.permission.BROADCAST_SMS">
    <intent-filter android:priority="999">
        <action android:name="android.provider.Telephony.SMS_RECEIVED" />
    </intent-filter>
</receiver>
```

`android:permission="android.permission.BROADCAST_SMS"` is the non-obvious part: it means only the system can deliver to this receiver, despite `exported="true"`. Do not drop it.

### 2.3 Rewrite, do not port

- **Persistence.** DataStore + hand-rolled `org.json` arrays is wrong for thousands of transactions needing date-range queries and category rollups — `decode()` deserialises the entire array on every read. **Room + SQLCipher.** Lift `SessionCrypto`, discard the substrate.
- **The `getOrDefault(emptyList())` swallow.** `ScannedContentStore.kt:87` treats a decrypt failure as "no data". For alert history that is acceptable; for a ledger it means **silent total history loss**. Decrypt failure must raise a visible, blocking error state.
- **`allowBackup`.** Set `android:allowBackup="false"` and `android:dataExtractionRules` explicitly in the first commit. It defaults to **true**; a fresh manifest re-arms the `AEADBadTagException` fuse, and the failure mode is a user migrating phones losing their entire ledger with no error shown.

### 2.4 Net-new, budget as greenfield

- **Everything classification.** `PreFilterEngine` and `CombinedScorer` do not exist in the donor repo. Classification there is one Retrofit call to a FastAPI backend that has no transaction parser. Amount / merchant / account-tail / direction extraction: 100% new.
- **Inbox backfill.** No `READ_SMS` permission has ever been in that repo; no `content://sms` query anywhere. A ledger needs history on day one. 100% new.
- **The account model and the ledger core.** Nothing analogous exists.
- **Bills, recurring detection, reconciliation, budgets.** New.

### 2.5 Before you write a line: extract a library module

`digikavach-v2` and `digikavach-lite` share **no module**; fixes are hand-ported in both directions and several remain unported. A third app makes that a three-way manual port. Extract `:core-crypto` (SessionCrypto), `:core-ui` (theme + components + charts) into a real Gradle library module **first**. This is a one-day job now and a permanent tax if deferred.

---

## 3. Architecture

```
                        ┌──────────────────────────────────────────┐
  SOURCES               │ 1. SmsReceiver (BROADCAST_SMS, prio 999)  │  realtime
                        │    goAsync() → IO scope → finish()        │
                        │ 2. BackfillWorker (READ_SMS, content://sms)│  one-shot + repair
                        │ 3. ShareTargetActivity (user shares text)  │  non-derivative fallback
                        │ 4. StatementImporter (CSV/PDF the user picks)│ non-derivative fallback
                        │ 5. ManualEntrySheet                        │  always available
                        └───────────────┬──────────────────────────┘
                                        │ RawMessage(sender, body, tsMillis, subId, source)
                                        ▼
                        ┌──────────────────────────────────────────┐
  INGEST QUEUE          │ Channel<Unit>(64) + 2 drain coroutines    │
  (from ScamNotifica-   │ ConcurrentHashMap<key,Job> in-flight dedup│
   tionListener shape)  │ @Synchronized updateEligibility()          │
                        └───────────────┬──────────────────────────┘
                                        ▼
   ┌────────────────────────────────────────────────────────────────────────┐
   │ STAGE 0  TRUST GATE + EXTRACTION                                        │
   │  normalise (NFKC, ZW/bidi strip, \n→space)                              │
   │  sender trust  → REGISTERED_FINANCIAL | OTHER | MSISDN(reject) | -P(reject)│
   │  template family match (F1..F11, declarative JSON rules)                 │
   │  extract amount(Long paise) direction tail rail ref vpa counterparty bal │
   │  reject/route table → OTP drop | balance-snapshot | BILL | MANDATE | drop │
   │  dedup: sha256(issuer|ref) strong, (tail,amount,dir,±90s) weak           │
   └───────────────┬────────────────────────────────────────────────────────┘
                   │ GateResult                     ┌──────────────┐
                   ▼                                │ non-txn routes│
   ┌────────────────────────────────────────┐       │ → bills       │
   │ STAGE 1..6  CATEGORIZATION CASCADE      │       │ → balances    │
   │  0.5 user rules (short-circuit)          │       │ → mandates    │
   │  1 exact merchant dict  (≥0.90 stop)     │       └──────────────┘
   │  2 fuzzy/token index    (≥0.82 accept)   │
   │  3 VPA shape heuristics                  │
   │  4 rail/channel signals                  │
   │  5b recurrence boost (confidence only)   │
   │  6 tiny on-device linear model           │
   │  → Classification(flowType, flowConf,    │
   │       categoryId, catConf, evidence[])   │
   └───────────────┬────────────────────────┘
                   ▼
   ┌────────────────────────────────────────────────────────────────────────┐
   │ LEDGER CORE  (Room + SQLCipher, all on-device)                          │
   │  account (ASSET_BANK|LIABILITY_CARD|CASH|WALLET|INVESTMENT|LOAN|EXTERNAL)│
   │  txn  ──1:N──  posting (account_id, signed_paise)  Σ postings = 0        │
   │  transfer_link | reversal_link | recurring_series | bill | budget        │
   │  reconciliation against bank-stated Avl Bal                              │
   └───────────────┬────────────────────────────────────────────────────────┘
                   ▼
   ┌────────────────────────────────────────────────────────────────────────┐
   │ UI (Compose)  Home · Ledger · Inbox(!) · Insights · Accounts · Settings  │
   │  three denominators: SPEND · CASHFLOW · NET WORTH                        │
   └────────────────────────────────────────────────────────────────────────┘

   NETWORK: none on the transaction path. Ever.
   Optional, opt-in: signed rule/dictionary bundle DOWNLOAD only. Nothing uploads.
```

**The hard invariant:** every stage from the receiver to the ledger completes offline, on-device, in under ~15 ms on a 2019 budget phone. The user swipes a card in a basement parking lot and still expects the notification. If any stage needs the network, the design is wrong.

---

## 4. SMS ingestion, trust gate, and the declarative parser format

### 4.1 Permissions (exactly these, nothing else)

```xml
<uses-permission android:name="android.permission.RECEIVE_SMS"/>
<uses-permission android:name="android.permission.READ_SMS"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

`RECEIVE_SMS` for realtime, `READ_SMS` for the one-time inbox backfill. Both are inside the money-management exception group. **Do not add `SEND_SMS`, `WRITE_SMS`, any Call Log permission, or `QUERY_ALL_PACKAGES`.** Every extra permission in the manifest is a separate thing the reviewer must be convinced of, and `QUERY_ALL_PACKAGES` in particular has no budgeting justification and will fail review. `READ_CONTACTS` is optional and must never be requested during onboarding (§5, Stage 3).

`android:allowBackup="false"` in the same commit.

### 4.2 Realtime receiver

```kotlin
@AndroidEntryPoint
class SmsReceiver : BroadcastReceiver() {
    @Inject lateinit var ingest: IngestQueue
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val sender = msgs.firstOrNull()?.originatingAddress ?: return
        val body = msgs.joinToString("") { it.messageBody.orEmpty() }   // multipart
        val subId = intent.getIntExtra("subscription", -1)              // dual SIM
        val pending = goAsync()
        scope.launch {
            try {
                ingest.offer(RawMessage(sender, body, System.currentTimeMillis(), subId, Source.SMS_REALTIME))
            } finally { pending.finish() }
        }
    }
}
```

**No premium gate, no feature-flag gate inside the receiver.** DigiKavach's `SmsScanReceiver.kt:46` (`if (!tokens.isPremiumNow() || !prefs.smsEnabledNow()) return@launch`) shipped as a bug where the OS permission was granted, the switch read ON, and the guard never ran. If ingestion is ever disabled, the receiver must not be registered at all, and the UI must say why.

### 4.3 Backfill

`READ_SMS` + `content://sms/inbox`, run once at first-run and re-runnable from Settings ("Rescan messages"). Chunk by 500 rows on a `WorkManager` expedited worker with a foreground notification showing progress; a 4-year inbox can be 30k+ rows and a `dataSync` FGS is the honest type for it. Backfill writes through the **same** pipeline as realtime — one code path, or the two will diverge and you will have two accuracy numbers.

Backfill ordering matters: process **oldest-first** so recurring detection, account discovery and transfer pairing build up naturally rather than seeing the newest row against an empty database.

### 4.4 The trust gate

```kotlin
enum class SenderTrust { REGISTERED_FINANCIAL, REGISTERED_OTHER, NUMERIC_MSISDN, UNKNOWN_SHORTCODE }
```

Strip the 2-character TSP/LSA prefix and the `-P` / `-S` / `-T` / `-G` DLT suffix to get the principal header; match case-insensitively (real traffic contains `AxisBk`, `axioFS`, `FiMony`).

- `REGISTERED_FINANCIAL` (header present in the shipped `issuer_header` table) → trust 1.0.
- **`-P` suffix → hard reject**, regardless of body. Promotional headers do not carry money movement.
- **`NUMERIC_MSISDN` (10-digit sender) → hard reject for ledger purposes.** Under DLT nobody can send a bank alert from a personal number; anything shaped like one is a spoof, prank or forward. Increment a counter, never create a transaction.
- `REGISTERED_OTHER` / `UNKNOWN_SHORTCODE` → confidence capped at **0.55**, so it can reach the Inbox for review but can never auto-post. This is how you onboard co-op banks and new fintechs without letting garbage in.

**Body retention is zero.** The ledger stores extracted fields plus a normalised counterparty string, never the SMS body, and a 16-byte body hash for dedup. DigiKavach kept bodies in `scannedContent` because its backend only had a hash; the ledger has the opposite requirement. Debug bodies, if you need them, live in a debug-build-only table behind a developer toggle. This is both a real privacy commitment and your best Data Safety / review talking point.

### 4.5 Amount and date traps (each is a test case)

- Indian lakh grouping: `1,00,000.00` ≠ `100,000.00`. Do **not** write a grouping-aware regex. Strip all commas, parse with `BigDecimal`, **store paise as `Long`**. Never `Double`, never `Float`, anywhere in the stack.
- Bare amounts with no prefix (SBI: `debited by 150.0`).
- `Rs.` / `Rs` / `INR` / `₹` / `Rs ` with and without space.
- Helpline digit runs (`18002586161`, `7308080808`, `1930`) will be eaten by a greedy reference-number regex. Anchor ref extraction to `Ref|RRN|UTR|Txn|UPI No` labels only, and blocklist known helpline numerals.
- Negation: `has not been debited`, `could not be debited`, `failed to debit` must be negative-lookaround guarded — the same trick `LocalMessageCheck` already uses for OTP-sharing.
- Date: templates carry `dd/MM/yy`, `dd-MM-yyyy`, `dd-MMM-yy`, and some carry none. When absent, fall back to the SMS receive timestamp and set `dateIsInferred = true` — the ledger must know the difference for month-boundary transactions.

### 4.6 Reject / route table

Non-transaction messages are not all garbage. Several are valuable on a *different* pipeline.

| Shape | Signal | Route |
|---|---|---|
| OTP | `OTP`, `one[- ]time password`, `do not share` | drop |
| Promotional | `-P` header, `apply now`, `% off`, `pre-approved` | drop |
| Balance-only | `Avl Bal` / `available balance`, no debit/credit verb | → **balance snapshot** (sets account balance, no txn) |
| Statement / bill due | `Total Amount Due`, `Min Amt Due`, `due on` | → **bills pipeline**, creates an upcoming bill, not a txn |
| Mandate pre-debit | `will be debited on`, `e-mandate`, `NACH will be presented` | → **upcoming recurring**, not a txn |
| Declined / failed | `declined`, `insufficient balance`, `could not be processed` | drop, increment per-issuer counter |
| Anything else from a financial header | — | drop |

### 4.7 The declarative rule format

Rules ship as a signed JSON bundle in `assets/rules/`, versioned, with an optional opt-in download of newer bundles (download only — nothing uploads). Keeping them declarative means a new bank template is a data change, not a release.

```json
{
  "bundleVersion": 47,
  "minAppVersion": 1,
  "normalizerVersion": 3,
  "issuers": [
    { "id": "HDFC", "headers": ["HDFCBK", "HDFCBN", "HDFCB"], "displayName": "HDFC Bank" },
    { "id": "SBI",  "headers": ["SBIINB", "SBIPSG", "ATMSBI", "CBSSBI"], "displayName": "State Bank of India" },
    { "id": "SBICARD", "headers": ["SBICRD", "SBICARD"], "displayName": "SBI Card" }
  ],
  "rules": [
    {
      "id": "hdfc.acct.debit.upi.v3",
      "issuerId": "HDFC",
      "family": "F5_RAIL_TOKEN",
      "priority": 100,
      "match": "(?i)^\\s*Sent\\s+Rs\\.?\\s*(?<amount>[\\d,]+(?:\\.\\d{1,2})?)\\s+From\\s+HDFC\\s+Bank\\s+A/C\\s*(?<tail>[Xx*]*\\d{4})\\s+To\\s+(?<counterparty>.+?)\\s+On\\s+(?<date>\\d{2}/\\d{2}/\\d{2})",
      "direction": "DEBIT",
      "instrument": "ACCOUNT",
      "rail": "UPI",
      "dateFormat": "dd/MM/yy",
      "capture": {
        "amount": "amount", "tail": "tail",
        "counterpartyRaw": "counterparty", "valueDate": "date"
      },
      "extract": [
        { "field": "refNo", "regex": "(?i)Ref\\s*(?:No\\.?|:)?\\s*(\\d{9,14})" },
        { "field": "vpa",   "regex": "([a-zA-Z0-9._-]{2,256}@[a-zA-Z]{2,64})" }
      ],
      "confidence": 0.95
    },
    {
      "id": "sbicard.spend.v2",
      "issuerId": "SBICARD",
      "family": "F4_CARD_SPEND",
      "priority": 100,
      "match": "(?i)Rs\\.?\\s*(?<amount>[\\d,]+(?:\\.\\d{1,2})?)\\s+spent\\s+on\\s+your\\s+SBI\\s+Credit\\s+Card\\s+ending\\s+(?:with\\s+)?(?<tail>\\d{4})\\s+at\\s+(?<counterparty>.+?)\\s+on\\s+(?<date>\\d{2}/\\d{2}/\\d{2})",
      "direction": "DEBIT",
      "instrument": "CREDIT_CARD",
      "rail": "POS_OR_ECOM",
      "dateFormat": "dd/MM/yy",
      "capture": { "amount": "amount", "tail": "tail", "counterpartyRaw": "counterparty", "valueDate": "date" },
      "confidence": 0.95
    },
    {
      "id": "generic.nach.debit.v1",
      "issuerId": "*",
      "family": "F7_LABELLED",
      "priority": 40,
      "match": "(?i)(?<rail>ACH[-/ ]?D|NACH|ECS)[-/ ]?(?<counterparty>[A-Z0-9 .&*_-]{3,40}).{0,40}?(?:Rs\\.?|INR)\\s*(?<amount>[\\d,]+(?:\\.\\d{1,2})?)",
      "direction": "DEBIT",
      "instrument": "ACCOUNT",
      "rail": "NACH",
      "capture": { "amount": "amount", "counterpartyRaw": "counterparty" },
      "confidence": 0.80
    },
    {
      "id": "route.billdue.v1",
      "issuerId": "*",
      "family": "ROUTE_BILL",
      "priority": 200,
      "match": "(?i)(Total\\s+Amount\\s+Due|Min(?:imum)?\\s+Amt?\\.?\\s+Due)",
      "route": "BILL",
      "extract": [
        { "field": "totalDuePaise", "regex": "(?i)Total\\s+Amount\\s+Due[^0-9]{0,12}(?:Rs\\.?|INR)?\\s*([\\d,]+(?:\\.\\d{1,2})?)" },
        { "field": "minDuePaise",   "regex": "(?i)Min(?:imum)?\\s+Amt?\\.?\\s+Due[^0-9]{0,12}(?:Rs\\.?|INR)?\\s*([\\d,]+(?:\\.\\d{1,2})?)" },
        { "field": "dueDate",       "regex": "(?i)due\\s+(?:on|by)\\s+(\\d{2}[-/][A-Za-z0-9]{2,3}[-/]\\d{2,4})" },
        { "field": "tail",          "regex": "(?i)(?:card|a/?c)\\s*(?:no\\.?|ending|XX)?\\s*[Xx*]*(\\d{4})" }
      ]
    },
    {
      "id": "reject.otp.v1",
      "issuerId": "*",
      "family": "REJECT",
      "priority": 1000,
      "match": "(?i)\\b(OTP|one[- ]time\\s+password|verification\\s+code)\\b",
      "route": "DROP"
    }
  ]
}
```

Rule engine contract:
- Rules are tried in descending `priority`, then by `issuerId` specificity (exact issuer beats `*`).
- `ROUTE_*` and `REJECT` families are evaluated **before** transaction families — a bill-due SMS that also contains `Rs.` must not become a transaction.
- A rule that matches but fails to yield `amount` + `direction` is a **miss**, not a match; fall through.
- Every rule carries a stable `id`. The `txn` row stores `matchedRuleId` and `bundleVersion`, so when a rule is later found wrong you can find and re-parse exactly the affected rows.
- Regexes are compiled once at bundle load and cached. Cap each rule at a compiled-regex timeout budget; a catastrophic-backtracking rule in a downloaded bundle must not hang the receiver. Prefer possessive/atomic constructs and bounded quantifiers — note the `{0,40}?` bounds above rather than `.*?`.

---

## 5. The categorization engine

**This is the section the whole product lives or dies on.**

### 5.1 The core insight: category is not one axis, it is two

Every naive Indian expense tracker has one field, `category: String`, and stuffs "Food", "Transfer" and "Mutual Fund" into the same enum. Then it sums all debits and says *"You spent ₹1,84,000 this month."* The user looks once, says "I didn't spend two lakhs," and never opens the app again.

A ledger entry carries two orthogonal fields:

```kotlin
enum class FlowType {
    SPEND,             // real consumption; leaves net worth; counts in "spent this month"
    INCOME,            // salary, interest, rent received
    INTERNAL_TRANSFER, // your money between YOUR containers; net worth unchanged
    P2P_TRANSFER,      // to/from another person; ambiguous until the user says
    INVESTMENT,        // asset changes form (cash → MF units); net worth unchanged
    DEBT_SERVICE,      // EMI/card bill: principal is balance-sheet, interest is spend
    REFUND,            // negative SPEND against the ORIGINAL category, never income
    FEE,               // always SPEND, broken out because nobody budgets for it
    UNKNOWN
}

enum class Direction { DEBIT, CREDIT }
```

`Direction` is what the SMS literally says. `FlowType` is what it *means*. `categoryId` is a leaf slug that only carries meaning for `SPEND`, `INCOME` and `FEE`.

### 5.2 Four double-counts that happen on a normal phone in a normal month

**(a) The credit card bill.** 40 swipes on HDFC CC in October = ₹38,000 of real spend, each with its own SMS. On 5 November: `Amt Deducted! Rs.38000 from your HDFC Bank A/c XX0601 for Money Transfer`. A naive tracker counts ₹76,000.

The bill payment is `INTERNAL_TRANSFER → transfers.card_bill_payment` — **provided the app has seen ≥1 transaction from that card in the last 45 days.** If it hasn't (the user's ICICI card sends no SMS to this phone), the bill payment is the *only* evidence that spending happened, so it must be reclassified `SPEND → misc.untracked_card_spend`. This conditional is not optional; it is the difference between a tracker that undercounts and one that double-counts, and both are fatal.

**(b) The wallet top-up.** ₹2,000 to PAYTM WALLET, then ₹500 at a kirana from wallet balance. The top-up is `INTERNAL_TRANSFER` into a virtual wallet account; the ₹500 is the spend. But many wallet spends produce no SMS at all — so expose a per-wallet `treatTopUpAsSpend: Boolean`. Default ON for a wallet where you have never seen a downstream spend SMS; flip OFF the first time you do. Surface it in Settings. Never decide silently.

**(c) The SIP.** ₹10,000/month `ACH-D-INDIAN CLEARING CORP`. This is the most damaging misclassification in the product, because the user doing the *right* thing gets told they are the biggest spender. `INVESTMENT → investments.mf_sip`. Counting it as spend makes a savings rate mathematically impossible and makes the app actively demoralising.

**(d) The self-transfer.** `Rs. 50000 debited from a/c *1234 to a/c **5678`. If `5678` matches a tail the user owns: `INTERNAL_TRANSFER → transfers.self_transfer`, ₹0 spend. Rule: destination tail matches a known own-account tail **AND** (same issuer OR the user linked it) **AND** a matching credit lands within ±10 minutes at the same paise value.

### 5.3 Three denominators, three screens

| View | Includes | Answers |
|---|---|---|
| **Spend** (the pie, the budgets) | `SPEND` + `FEE` + the interest portion of `DEBT_SERVICE`; minus `REFUND` | "Where did my money go?" |
| **Cashflow** (the treasury view) | every rupee that left the account, incl. transfers, SIPs, principal | "Can I make rent this month?" |
| **Net worth delta** | `INCOME` − `SPEND` − `FEE` − interest; investments and principal move between asset lines | "Am I getting richer?" |

The SIP appears in Cashflow and in Net worth (as an asset increase) but **never** in Spend. Say this in the UI the first time it happens: *"We kept your ₹10,000 SIP out of your spending total — it's savings, not spending. Tap to change."* That card is the highest-trust moment the app will ever have.

### 5.4 The taxonomy

Slugs are **immutable strings** — never integers, never reordered, never deleted (only `deprecated=1` plus a `category_alias` redirect). User rules and dictionary entries reference these slugs; a rename is a data-loss bug.

```
food_dining              .restaurant .delivery .cafe .street_quick
                         .bar_alcohol .office_canteen .tiffin_mess
groceries                .supermarket .quick_commerce .kirana
                         .dairy_milk .meat_fish .fruits_veg
transport                .cab .bike_auto .metro_local .bus_public
                         .fuel .tolls_parking .vehicle_service
travel                   .flights .trains .intercity_bus .stay
                         .packages_tours .visa_forex
shopping                 .ecom_mixed .fashion .electronics .home_furniture
                         .beauty_personal .gifts .books_stationery
entertainment            .ott_video .music_audio .movies_events .gaming
                         .apps_software .news_reading .hobby_clubs
bills_utilities          .electricity .water .piped_gas .lpg_cylinder
                         .mobile_postpaid .mobile_recharge .broadband .dth_cable
housing                  .rent .society_maintenance .household_help
                         .repairs_improvement .deposits_brokerage
health                   .pharmacy .doctor .diagnostics .hospital
                         .dental .vision .fitness .wellness_therapy
education                .tuition_coaching .school_college_fees
                         .online_courses .exam_fees .edu_supplies
insurance                .health_insurance .life_term .motor .other_insurance
emi_loans      [DEBT_SERVICE]  .home_loan .vehicle_loan .personal_loan
                         .education_loan .consumer_durable .credit_card_emi
                         .bnpl .loan_interest
investments    [INVESTMENT, countsAsSpend=false]  .mf_sip .mf_lumpsum .stocks
                         .gold_digital .fd_rd .nps_ppf_epf .ulip_endowment .crypto
transfers      [countsAsSpend=false]  .self_transfer .card_bill_payment
                         .wallet_topup .p2p_sent .p2p_received
                         .atm_withdrawal .cash_deposit
income         [INCOME]  .salary .business .freelance .interest .dividend
                         .rent_received .cashback_rewards .maturity_redemption
                         .govt_benefit .gift_received .refund
cash                     .cash_spend .cash_unaccounted
fees_charges   [FEE]     .bank_charges .atm_fee .late_fee .annual_card_fee
                         .bounce_penalty .forex_markup .convenience_fee
                         .brokerage_dp .gst_on_charges
taxes                    .advance_tax .income_tax .property_tax
                         .professional_tax .gst_paid
charity_religious        .donation .religious_offering
misc                     .uncategorized .unknown_merchant
                         .untracked_card_spend .excluded
```

Deliberate, India-specific choices worth defending:

- **`groceries.quick_commerce` is split from `.supermarket`.** Blinkit/Zepto/Instamart have ~4× the frequency and ~1/5 the basket of a DMart run. Merging them destroys the one insight the user actually wants.
- **`housing.household_help`** — maid, cook, driver: a recurring P2P UPI to a person. A huge Indian category that every tracker gets wrong by calling it `transfers.p2p_sent`.
- **`housing.rent`** is usually a P2P UPI/IMPS to a landlord. **Recurrence is the only signal.** There is no merchant string to match.
- **`insurance` is top-level, not under bills.** Indians budget it as one line.
- **`insurance.life_term` (pure cost, SPEND) is distinct from `investments.ulip_endowment` (INVESTMENT).** Merging them corrupts the savings rate.
- **`housing.deposits_brokerage`** has `countsAsSpend = false` — a security deposit is a receivable. But a non-refundable brokerage fee really is spend, which is why per-transaction `flowTypeOverride` exists.
- **`misc.uncategorized` is the Inbox.** It is never assigned by a guess.

```kotlin
data class CategoryDef(
    val slug: String,                 // "food_dining.delivery" — IMMUTABLE
    val parentSlug: String?,
    val displayNameKey: String,       // string resource key, for hi/ta/te/bn/kn
    val defaultFlowType: FlowType,
    val countsAsSpend: Boolean,       // in the pie and budgets
    val countsAsCashOutflow: Boolean, // in the cashflow view
    val isDiscretionary: Boolean,     // powers needs-vs-wants; .rent false, .ott_video true
    val defaultBudgetable: Boolean,
    val iconKey: String,
    val colorToken: String,
    val deprecated: Boolean = false,
    val sortOrder: Int                // display only; NEVER an identity
)
```

**Refund rule.** A `REFUND` credit is stored as a normal transaction with a **negative signed amount in the original transaction's category**, linked via `reversalOfTxnId`. It reduces October's food spend; it does not inflate October's income. Only an unmatchable refund (no candidate debit within 45 days, ±2% amount, same merchant root) falls back to `income.refund`.

### 5.5 The cascade: cost order and authority order are different axes

- **Cost order** (cheap first): hash lookup → token index → regex → arithmetic → model.
- **Authority order** (who wins): the user > a learned rule > the shipped dictionary > a heuristic > a model > nothing.

A user rule is *both* the cheapest lookup and the highest authority, so it is evaluated at position 0.5 and short-circuits everything. Write this comment in the code, because in four months you will "optimise" it into the wrong place.

```kotlin
// Ordered by COST. Authority is enforced by minAuthorityToOverride, not by position.
suspend fun classify(gate: GateResult): Classification {
    Stage5_Rules.lookup(gate)?.let { return it.apply(gate) }   // HARD short-circuit

    var best = Candidate.none()
    for (stage in listOf(S1_ExactDict, S2_Fuzzy, S3_Vpa, S4_Channel)) {
        best = best.mergeWith(stage.run(gate, best))           // later stages read earlier partials
        if (best.categoryConfidence >= stage.shortCircuitAt) break
    }
    if (best.categoryConfidence < 0.60) best = best.mergeWith(S6_Model.run(gate, best))
    best = S5b_Recurrence.boost(best)                          // confidence only, never a category change
    return best.toClassification()                             // < 0.45 → misc.uncategorized, into the Inbox
}
```

```kotlin
data class Classification(
    val flowType: FlowType,
    val flowConfidence: Float,        // separate on purpose — see Stage 3
    val categoryId: String,
    val categoryConfidence: Float,
    val merchantId: Long?,
    val source: ClassificationSource, // USER_RULE, DICT_EXACT, DICT_FUZZY, VPA, RAIL, MODEL, NONE
    val evidence: List<String>,       // human-readable, shown in the "why?" sheet
    val rulesBundleVersion: Int,
    val normalizerVersion: Int
)
```

#### Stage 1 — exact merchant dictionary

`MerchantNormalizer` (version-stamped; the version matters more than the algorithm, because re-normalising under a new version invalidates cached `norm_key`s):

1. Uppercase, NFKC.
2. Strip aggregator/acquirer prefixes: `RAZ*`, `RAZORPAY*`, `PAYU*`, `PAYU_`, `BILLDESK`, `CCAVENUE`, `PYTM*`, `PAYTM-`, `EAZYDINE`, `PZCREDIT`, `PAYZAPP`, `INB/`, `UPI/`, `POS/`, `ACH-D-`, `ACH/`, `NEFT/`, `IMPS/`, `MMT/`, `VPS*`, `SI/`.
3. Strip trailing terminal/merchant IDs: `\s*[0-9]{4,}$` (`EAZYDINE0000000` → `EAZYDINE`).
4. Strip trailing geography: `\b(BANGALORE|BENGALURU|MUMBAI|DELHI|NEW DELHI|HYDERABAD|CHENNAI|PUNE|KOLKATA|GURGAON|GURUGRAM|NOIDA)\b` + optional `\b(IND|IN|INDIA)\b$`.
5. Collapse non-alphanumerics to single spaces; trim.
6. Drop corporate-form tokens: `PVT PRIVATE LTD LIMITED LLP INDIA INDIAN TECHNOLOGIES TECHNOLOGY SOLUTIONS SERVICES SERVICE RETAIL ENTERPRISES VENTURES CORP CO`.
7. Result = `normKey`; also emit `tokens: List<String>` for Stage 2.

Lookup: `SELECT merchant_id, confidence FROM merchant_alias WHERE norm_key = ?` — unique index, one B-tree hit. VPA local-parts are stored as alias rows too (`swiggystores`, `zomato`, `bigbasket`), so a known-merchant VPA resolves here and never reaches Stage 3.

Confidence: **0.99** local `user_merchant`, **0.97** curated alias, **0.93** auto-derived alias. **Short-circuit at ≥ 0.90.**

This stage must resolve **60–70% of transactions** for an urban user, because spend is brutally head-heavy. If it doesn't, the dictionary is the problem, not the cascade.

#### Stage 2 — fuzzy / token match

Do **not** run Levenshtein over 5,000 entries per SMS.

Candidate generation: inverted index `merchant_token(token, merchant_id, idf)`. Take the two highest-IDF tokens from the input, union their posting lists → typically 3–20 candidates. Fall back to a trigram table when no token clears an IDF floor.

```
score = 0.55 * weightedTokenSetJaccard(inputTokens, merchantTokens, idf)
      + 0.25 * prefixBonus(longestCommonPrefix / len)
      + 0.20 * (1 - normalizedEditDistance(bestAlignedToken))
```

- `score ≥ 0.82` → accept; `confidence = 0.72 + 0.20*(score-0.82)/0.18`, capped at **0.88**.
- `0.65 ≤ score < 0.82` → **suggestion only**, confidence 0.50, goes to the Inbox pre-filled.
- `< 0.65` → fall through.

Guards that prevent the classic disasters:

- Tokens of length ≤ 3 and pure-numeric tokens **cannot drive** a match; they only add score once another token has matched.
- `merchant.blockFuzzy = 1` on short/ambiguous names. `JIO` must not fuzzy-match `JIOMART` (Bills vs Groceries) or `JIOSTAR` (Entertainment). Those get explicit alias rows.
- **A fuzzy match may never cross a `flowType` boundary.** Matching `SBI` against `SBICARD` would flip SPEND into DEBT_SERVICE. Forbid it structurally: if `candidate.flowType != partial.flowTypePrior` and the prior confidence > 0.7, reject the candidate.

The alias corpus is the actual work. Card rails carry legal-entity names, not brands:

`BUNDL TECHNOLOGIES → Swiggy` · `KIRANAKART → Zepto` · `BLINK COMMERCE` / `GROFERS → Blinkit` · `SUPERMARKET GROCERY SUPPLIES` / `INNOVATIVE RETAIL CONCEPTS → BigBasket` · `ANI TECHNOLOGIES → Ola` · `ROPPEN TRANSPORTATION → Rapido` · `FASHNEAR TECHNOLOGIES → Meesho` · `APPARIO RETAIL` / `CLICKTECH RETAIL → Amazon` · `ONE97 COMMUNICATIONS → Paytm` · `DREAMPLUG → CRED` · `BILLIONBRAINS → Groww` · `CUREFIT → Cult.fit` · `BIGTREE ENTERTAINMENT → BookMyShow` · `LE TRAVENUES → Ixigo` · `INTERGLOBE AVIATION → IndiGo` · `AXELIA SOLUTIONS` / `API HOLDINGS → PharmEasy` · `THINK AND LEARN → BYJU'S` · `VITALIC HEALTH → Netmeds`.

#### Stage 3 — UPI VPA heuristics

Parse `local@psp`. **The PSP handle is almost worthless for category** — write that in the code comment, because it is the trap every first implementation falls into. `@ybl`, `@paytm`, `@okaxis`/`@okhdfcbank`/`@oksbi`, `@apl`, `@upi`, `@waaxis`, `@fam`, `@slice`, `@jupiteraxis`, `@naviaxis`, `@fbpe`, `@axisb`, `@idfcbank` tell you which *app* the counterparty uses, not what they sold. The one exception: `@okbizaxis` and BharatPe/Paytm-QR handles are merchant-acquiring handles → strong P2M prior.

All the signal is in the **local part**:

```kotlin
sealed interface VpaShape {
    object MerchantQrOpaque : VpaShape  // q123456789@ybl, paytmqr2810...@paytm, bharatpe.90xxxxx@fbpe
    object MerchantNamed    : VpaShape  // swiggystores@icici — should have hit Stage 1
    object PersonPhone      : VpaShape  // ^[6-9]\d{9}$
    object PersonName       : VpaShape  // firstname.lastname, firstname1234
    object Ambiguous        : VpaShape
}
```

Detection, in order:
1. Local matches `^(paytmqr|bharatpe|q|mab|gpay-|merchant|pay|store|shop|bpay|razorpay|payu)[a-z0-9._-]{4,}$`, or is ≥ 12 chars of opaque alphanumerics → `MerchantQrOpaque`.
2. Local matches `^[6-9]\d{9}$` → `PersonPhone`.
3. Local is a `.`-separated pair of dictionary-absent alpha tokens, or matches a device contact → `PersonName`. **Contacts matching requires `READ_CONTACTS`, which you must never request during onboarding.** Make it an optional "recognise my contacts" toggle deep in Settings, matched purely on-device, and ship happily without it.
4. Otherwise `Ambiguous`.

Outputs, and the crucial asymmetry:

| Shape | flowType | flowConf | category | catConf |
|---|---|---|---|---|
| `MerchantQrOpaque` | `SPEND` | **0.88** | `misc.unknown_merchant` | 0.25 |
| `PersonPhone` / `PersonName` | `P2P_TRANSFER` | 0.80 | `transfers.p2p_sent` | 0.55 |
| `Ambiguous` | `SPEND` | 0.60 | — | 0.10 |

A QR-code UPI payment to a tea stall gives you **high confidence it was spend and near-zero confidence about what kind**. Those are different numbers and must be stored as different fields. This is the entire reason `Classification` carries `flowConfidence` and `categoryConfidence` separately, and it is the thing that lets the Home screen say "₹43,200 spent" honestly while the pie still shows a grey "Unsorted ₹4,320" slice.

Amount priors are a **weak nudge only**: `MerchantQrOpaque` + amount < ₹200 → +0.12 toward `food_dining.street_quick` / `groceries.kirana`. Never enough on its own to cross 0.45.

**The highest-value moment in the entire product lives here.** The first time `q9876543210@ybl` appears, you ask. The second time, the learned rule fires and it is silently "Chai — Food & Dining" forever. Instrument this: *percentage of unknown-VPA transactions auto-resolved by a user rule* is the single best health metric you have.

#### Stage 4 — rail / channel signals

**There is no MCC in an SMS.** Say it plainly in the code: MCC lives in the card-network authorisation message, which never reaches the handset. What you have is the rail and the instrument, and they are mostly a `flowType` oracle, not a category oracle.

| Token | flowType | conf | Category prior |
|---|---|---|---|
| `ATM`, `CASH WDL`, `cash withdrawal` | `INTERNAL_TRANSFER` | 0.95 | `transfers.atm_withdrawal` 0.95 |
| `NACH`, `ACH-D`, `ECS`, `e-mandate`, `SI ` | varies | 0.85 | decide by the ACH originator string |
| `ACH-D-INDIAN CLEARING CORP`, `BSE LIMITED`, `ISIP` | `INVESTMENT` | 0.92 | `investments.mf_sip` 0.90 |
| `UPI-AUTOPAY`, `UPI Mandate` | `SPEND` | 0.85 | `entertainment.*` 0.35 |
| `EMI`, `Instalment`, `Installment` | `DEBT_SERVICE` | 0.90 | `emi_loans.*` 0.75 |
| `IMPS`/`NEFT`/`RTGS` + masked a/c, no name | `P2P_TRANSFER` or `INTERNAL_TRANSFER` | 0.70 | — |
| `POS` on a `LIABILITY_CARD` account | `SPEND` | 0.92 | — |
| Credit to a `LIABILITY_CARD` from a known own bank account | `INTERNAL_TRANSFER` | 0.93 | `transfers.card_bill_payment` (conditional, §5.2a) |

Stage 4 can raise `flowConfidence` to near-certainty while leaving `categoryConfidence` at 0.1. That is a correct and useful outcome, not a failure.

#### Stage 5 — user rules (evaluated first, defined here)

```kotlin
@Entity(tableName = "user_rule")
data class UserRule(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val matchKind: MatchKind,        // NORM_KEY | VPA_EXACT | VPA_LOCAL | TAIL_PLUS_AMOUNT | REGEX | MERCHANT_ID
    val matchValue: String,
    val amountMinPaise: Long? = null,   // scope by amount band
    val amountMaxPaise: Long? = null,
    val accountId: Long? = null,        // scope to one account
    val setFlowType: FlowType?,
    val setCategoryId: String?,
    val setMerchantId: Long?,
    val setCounterpartyLabel: String?,  // "Chai stall", "Landlord"
    val excludeFromSpend: Boolean = false,
    val authority: Int = 100,           // 100 = explicit user; 60 = accepted suggestion
    val createdAt: Long,
    val hitCount: Int = 0,
    val lastHitAt: Long? = null
)
```

Rules are indexed by `(matchKind, matchValue)`; lookup is one hash hit. Conflicts resolve by `authority` then `createdAt` descending. A rule created from an explicit correction gets authority 100; one created by accepting a suggestion gets 60, so a later explicit correction beats it without a prompt.

#### Stage 5b — recurrence boost (confidence only, never a category change)

If the same `(normKey | vpa | tail+amountBand)` has fired ≥ 3 times at a consistent cadence (monthly ±4 days, weekly ±1 day), add **+0.10** to `categoryConfidence`, capped at 0.93, and tag the transaction into the `recurring_series`. Recurrence **must not** change the category — it only makes the existing guess more trustworthy. The one exception is `housing.rent` and `housing.household_help`, where recurrence of a P2P payment is a genuine *category* signal; that path requires user confirmation the first time and then becomes a user rule.

#### Stage 6 — the tiny on-device model

Only runs when `categoryConfidence < 0.60`. Keep it boring:

- **Multinomial logistic regression / linear SVM over hashed character 3–5-grams** of `normKey` + a handful of dense features (log amount, hour-of-day bucket, rail one-hot, instrument one-hot, day-of-month). ~30k hashed features × ~90 categories, int8 quantised weights ≈ 2.7 MB. One sparse dot product, sub-millisecond.
- Ships in `assets/`, versioned alongside the rules bundle. Retrained offline by you on the labelled corpus, never on-device, never on user data leaving the phone.
- **Output confidence is hard-capped at 0.75.** The model may never auto-post something the dictionary refused; it may only pre-fill the Inbox and improve the suggestion ordering.
- No transformer, no TFLite LLM, no embedding model. The budget is 15 ms total and a cold BroadcastReceiver process.

**[UNVERIFIED]** The 60–70% Stage-1 hit rate and the 0.82 fuzzy threshold are engineering estimates from the shape of Indian merchant traffic, not measured on your corpus. Section 12 exists to replace them with real numbers before v1 ships.

### 5.6 Confidence thresholds — the single table

| Band | Behaviour |
|---|---|
| `categoryConfidence ≥ 0.90` | Auto-post, silent. No notification beyond the normal "transaction added". |
| `0.75 ≤ c < 0.90` | Auto-post, but flagged `needsReview` — shows a small dot in the ledger; included in totals. |
| `0.45 ≤ c < 0.75` | **Inbox**, pre-filled with the best guess. Counts in Cashflow, counts in Spend only if `flowConfidence ≥ 0.80`, shows in the grey "Unsorted" pie slice. |
| `c < 0.45` | **Inbox**, no category guess. Category is `misc.uncategorized`. |
| `flowConfidence < 0.60` | Never counted in any total until resolved. Shows in the ledger as "Needs your input". |

Nothing about these numbers is sacred except the **shape**: there must be a band where the app says "I don't know" out loud. Tune the numbers against §12; do not tune away the band.

### 5.7 The learning loop

Every correction does four things, in this order:

1. **Fix the transaction.** Immediately, optimistically, with an undo snackbar.
2. **Create or strengthen a user rule** at the narrowest scope that explains the correction. Narrowest first: `VPA_EXACT` > `NORM_KEY` > `MERCHANT_ID`. Never silently create a broad rule.
3. **Offer retroactive application.** *"Also change 14 past transactions from this merchant?"* — with a count, never silently. Retroactive changes write an `edit_log` row per affected transaction so the user can undo the whole batch.
4. **Record a training example** in a local `labelled_example` table (normKey, features, chosen category, timestamp). This is the corpus for the *next* model version and for your accuracy dashboard. It never leaves the device unless the user explicitly taps "Help improve categorization" and the shared payload is the **normalised merchant key and chosen category only** — never an amount, never an account tail, never a body. Default OFF.

Anti-thrash guard: if the user corrects the *same* rule in opposite directions twice within 30 days, stop auto-creating rules for that key and ask explicitly what the rule should be. A ledger that keeps re-learning the wrong thing is how you lose a user permanently.

**Merchant dictionary shape:**

```kotlin
@Entity(tableName = "merchant")
data class Merchant(
    @PrimaryKey val id: Long,
    val canonicalName: String,        // "Swiggy"
    val defaultCategoryId: String,    // "food_dining.delivery"
    val defaultFlowType: FlowType,
    val blockFuzzy: Boolean = false,
    val isAggregator: Boolean = false,// Razorpay/PayU — never a real merchant
    val logoKey: String?,
    val source: DictSource            // SHIPPED | DOWNLOADED | USER
)

@Entity(tableName = "merchant_alias",
        indices = [Index(value = ["normKey"], unique = true)])
data class MerchantAlias(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val normKey: String,              // "BUNDL TECHNOLOGIES"
    val merchantId: Long,
    val confidence: Float,            // 0.97 curated, 0.93 derived, 0.99 user
    val normalizerVersion: Int
)
```

---

## 6. The ledger core

### 6.1 The largest design defect to avoid: no account model

A flat list of one-sided transactions with an `instrument` string cannot represent "money moved between two things I own". Every transfer, card bill, wallet top-up and SIP is then booked as consumption. **Accounts must be first-class entities with an owner and a type, and every transaction must have postings that sum to zero.**

The unknown side of a transaction posts to a synthetic `EXTERNAL` account. That keeps double-entry honest without requiring you to know who the counterparty banks with.

### 6.2 SQL DDL

```sql
-- ── ACCOUNTS ────────────────────────────────────────────────────────────────
CREATE TABLE account (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  kind            TEXT    NOT NULL,   -- ASSET_BANK|LIABILITY_CARD|CASH|WALLET|INVESTMENT|LOAN|EXTERNAL
  issuer_id       TEXT,               -- 'HDFC','SBICARD', NULL for CASH/EXTERNAL
  tail            TEXT,               -- '0601'; NULL for CASH/EXTERNAL
  display_name    TEXT    NOT NULL,
  currency        TEXT    NOT NULL DEFAULT 'INR',
  is_owned        INTEGER NOT NULL DEFAULT 1,  -- 0 for EXTERNAL
  opening_balance_paise INTEGER NOT NULL DEFAULT 0,
  credit_limit_paise    INTEGER,      -- LIABILITY_CARD only
  statement_day   INTEGER,            -- 1..31, LIABILITY_CARD
  due_day         INTEGER,
  treat_topup_as_spend INTEGER NOT NULL DEFAULT 0,  -- WALLET only, §5.2b
  is_archived     INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_account_identity ON account(issuer_id, tail, kind)
  WHERE issuer_id IS NOT NULL AND tail IS NOT NULL;

-- ── TRANSACTIONS ────────────────────────────────────────────────────────────
CREATE TABLE txn (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  value_date      TEXT    NOT NULL,   -- ISO-8601 local date
  date_is_inferred INTEGER NOT NULL DEFAULT 0,
  posted_at       INTEGER NOT NULL,   -- epoch millis the app learned of it
  amount_paise    INTEGER NOT NULL,   -- ALWAYS POSITIVE; sign lives in posting
  direction       TEXT    NOT NULL,   -- DEBIT|CREDIT (what the SMS said)
  flow_type       TEXT    NOT NULL,
  flow_confidence REAL    NOT NULL,
  category_id     TEXT    NOT NULL,
  category_confidence REAL NOT NULL,
  flow_type_override TEXT,            -- user override, wins over flow_type
  merchant_id     INTEGER REFERENCES merchant(id),
  counterparty_raw TEXT,
  counterparty_norm TEXT,
  counterparty_label TEXT,            -- user-given: "Landlord"
  vpa             TEXT,
  rail            TEXT,
  ref_no          TEXT,
  balance_after_paise INTEGER,        -- bank-stated Avl Bal, if present
  source          TEXT    NOT NULL,   -- SMS_REALTIME|SMS_BACKFILL|SHARE|IMPORT|MANUAL
  dedup_key       TEXT    NOT NULL,
  body_hash       BLOB    NOT NULL,   -- 16 bytes; the body itself is NEVER stored
  matched_rule_id TEXT,
  rules_bundle_version INTEGER,
  normalizer_version   INTEGER,
  classification_source TEXT,
  needs_review    INTEGER NOT NULL DEFAULT 0,
  is_excluded     INTEGER NOT NULL DEFAULT 0,
  superseded_by   INTEGER REFERENCES txn(id),
  reversal_of_txn_id INTEGER REFERENCES txn(id),
  recurring_series_id INTEGER REFERENCES recurring_series(id),
  notes           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_txn_dedup ON txn(dedup_key);
CREATE INDEX ix_txn_date        ON txn(value_date DESC, id DESC);   -- keyset paging
CREATE INDEX ix_txn_cat_date    ON txn(category_id, value_date);
CREATE INDEX ix_txn_review      ON txn(needs_review) WHERE needs_review = 1;
CREATE INDEX ix_txn_cp          ON txn(counterparty_norm);

-- ── POSTINGS (double entry) ─────────────────────────────────────────────────
CREATE TABLE posting (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  txn_id        INTEGER NOT NULL REFERENCES txn(id) ON DELETE CASCADE,
  account_id    INTEGER NOT NULL REFERENCES account(id),
  signed_paise  INTEGER NOT NULL,     -- negative leaves the account
  leg           TEXT    NOT NULL      -- SOURCE|DEST
);
CREATE INDEX ix_posting_acct ON posting(account_id, txn_id);
-- INVARIANT, asserted in a DAO transaction and in a debug-build CI check:
--   SELECT txn_id FROM posting GROUP BY txn_id HAVING SUM(signed_paise) <> 0
-- must return zero rows.

-- ── LINKS ───────────────────────────────────────────────────────────────────
CREATE TABLE transfer_link (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  debit_txn_id  INTEGER NOT NULL REFERENCES txn(id),
  credit_txn_id INTEGER NOT NULL REFERENCES txn(id),
  confidence    REAL    NOT NULL,
  method        TEXT    NOT NULL,     -- REF_MATCH|AMOUNT_TIME|USER
  created_at    INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_transfer_pair ON transfer_link(debit_txn_id, credit_txn_id);

-- ── RECURRING ───────────────────────────────────────────────────────────────
CREATE TABLE recurring_series (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  match_kind      TEXT    NOT NULL,   -- NORM_KEY|VPA|TAIL_AMOUNT
  match_value     TEXT    NOT NULL,
  cadence         TEXT    NOT NULL,   -- MONTHLY|WEEKLY|QUARTERLY|YEARLY
  expected_day    INTEGER,
  expected_amount_paise INTEGER,
  amount_tolerance_bp INTEGER NOT NULL DEFAULT 500,  -- 5%
  category_id     TEXT,
  is_confirmed    INTEGER NOT NULL DEFAULT 0,
  last_seen_date  TEXT,
  next_due_date   TEXT,
  missed_count    INTEGER NOT NULL DEFAULT 0
);

-- ── BILLS ───────────────────────────────────────────────────────────────────
CREATE TABLE bill (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id        INTEGER REFERENCES account(id),
  biller_name       TEXT    NOT NULL,
  total_due_paise   INTEGER,
  min_due_paise     INTEGER,
  due_date          TEXT,
  statement_date    TEXT,
  status            TEXT    NOT NULL,  -- UPCOMING|PARTIALLY_PAID|PAID|OVERDUE|IGNORED
  paid_by_txn_id    INTEGER REFERENCES txn(id),
  source            TEXT    NOT NULL,  -- SMS_STATEMENT|SMS_MANDATE|USER
  created_at        INTEGER NOT NULL
);

-- ── BALANCE SNAPSHOTS (reconciliation) ──────────────────────────────────────
CREATE TABLE balance_snapshot (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id    INTEGER NOT NULL REFERENCES account(id),
  as_of_millis  INTEGER NOT NULL,
  stated_paise  INTEGER NOT NULL,     -- what the bank SMS said
  derived_paise INTEGER,              -- what our ledger computed at that instant
  delta_paise   INTEGER,
  source_txn_id INTEGER REFERENCES txn(id)
);
CREATE INDEX ix_bal_acct ON balance_snapshot(account_id, as_of_millis DESC);

-- ── BUDGETS, CATEGORIES, RULES, AUDIT ───────────────────────────────────────
CREATE TABLE budget (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id TEXT NOT NULL, period TEXT NOT NULL,  -- MONTHLY
  amount_paise INTEGER NOT NULL, starts_on TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE edit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  txn_id INTEGER NOT NULL REFERENCES txn(id),
  field TEXT NOT NULL, old_value TEXT, new_value TEXT,
  actor TEXT NOT NULL,          -- USER|RULE|REPARSE|IMPORT
  batch_id TEXT,                -- groups a retroactive apply for one-tap undo
  at_millis INTEGER NOT NULL
);

CREATE TABLE labelled_example (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  norm_key TEXT, vpa TEXT, rail TEXT, instrument TEXT,
  amount_bucket INTEGER, hour_bucket INTEGER,
  chosen_category_id TEXT NOT NULL, chosen_flow_type TEXT NOT NULL,
  was_suggestion_accepted INTEGER NOT NULL, at_millis INTEGER NOT NULL
);
```

Room with SQLCipher (`net.zetetic:android-database-sqlcipher` + `SupportFactory`), passphrase generated once and sealed with `SessionCrypto`. `android:allowBackup="false"`.

### 6.3 Kotlin entity (the transaction as the app sees it)

```kotlin
@Entity(tableName = "txn", indices = [Index(value = ["dedup_key"], unique = true)])
data class TxnEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val valueDate: LocalDate,
    val dateIsInferred: Boolean = false,
    val postedAt: Long,
    val amountPaise: Long,              // ALWAYS POSITIVE
    val direction: Direction,
    val flowType: FlowType,
    val flowConfidence: Float,
    val categoryId: String,
    val categoryConfidence: Float,
    val flowTypeOverride: FlowType? = null,
    val merchantId: Long? = null,
    val counterpartyRaw: String? = null,
    val counterpartyNorm: String? = null,
    val counterpartyLabel: String? = null,
    val vpa: String? = null,
    val rail: String? = null,
    val refNo: String? = null,
    val balanceAfterPaise: Long? = null,
    val source: TxnSource,
    val dedupKey: String,
    val bodyHash: ByteArray,
    val matchedRuleId: String? = null,
    val rulesBundleVersion: Int? = null,
    val normalizerVersion: Int? = null,
    val classificationSource: ClassificationSource,
    val needsReview: Boolean = false,
    val isExcluded: Boolean = false,
    val supersededBy: Long? = null,
    val reversalOfTxnId: Long? = null,
    val recurringSeriesId: Long? = null,
    val notes: String? = null,
    val createdAt: Long, val updatedAt: Long
) {
    val effectiveFlowType: FlowType get() = flowTypeOverride ?: flowType
}
```

### 6.4 Double-count prevention — the four mechanisms

1. **Dedup at ingest.** Strong key `sha256(issuerId + "|" + refNo)`; weak key `(tail, amountPaise, direction)` within ±90 s. On collision, keep the SMS-sourced copy (richer fields) and set `superseded_by` on the other. The unique index on `dedup_key` makes this enforced by the database, not by a code path you might forget.
2. **Transfer pairing.** A debit and a credit are linked when: same `refNo` (confidence 0.98), **or** same `amountPaise` + opposite direction + both accounts owned + within ±10 minutes (0.85). Linked pairs post to two owned accounts, so the `EXTERNAL` leg disappears and `Spend` is untouched.
3. **Card-bill conditional.** A credit to a `LIABILITY_CARD` account from an owned `ASSET_BANK` is `transfers.card_bill_payment` **only if** ≥1 transaction exists on that card in the last 45 days. Otherwise `misc.untracked_card_spend` with `countsAsSpend = true`. Recompute this flag when a card starts producing transactions, and tell the user: *"We can now see your ICICI card directly, so we've stopped counting the bill payment as spending."*
4. **Reversal matching.** A credit whose `refNo` or (merchant root, ±2% amount, ≤45 days) matches an earlier debit becomes `flowType = REFUND` with `reversal_of_txn_id` set and a negative posting in the **original** category.

### 6.5 Reconciliation against bank-stated balance

Every SMS that carries `Avl Bal` writes a `balance_snapshot`. At snapshot time compute `derived_paise` = opening balance + sum of postings for that account up to `as_of_millis`, and store `delta_paise`.

- `delta == 0` → show a quiet green "matched as of <time>" on the account card. This is the strongest trust signal the app has, and it is free.
- `delta != 0` → the ledger is missing something. Show it **honestly and specifically**: *"We're ₹1,240 short on HDFC ••0601 since 14 Sep — probably a transaction we never saw an SMS for."* Offer "Add the missing amount as a cash/unknown adjustment" which writes a single `misc.unknown_merchant` transaction, and offer "Ignore".
- Never silently plug the gap. A plugged gap that the user didn't approve is exactly the class of error that destroys trust in a ledger.
- Persistent drift on one account over 3+ snapshots → surface a diagnostic: that account probably has a template the parser misses. This is also your best in-the-wild bug report channel.

### 6.6 Bills and matching

Bill-due SMS creates a `bill` row (never a transaction). A later debit matches it when: same account/biller, amount equals `total_due_paise` (→ `PAID`) or `min_due_paise` or anything in between (→ `PARTIALLY_PAID`), within the statement window. Unmatched by `due_date + 3` → `OVERDUE`, notify once.

For credit cards, the paid bill is the `INTERNAL_TRANSFER`, and any **interest or late fee** stated separately in the statement SMS is created as its own `FEE` transaction — that is real spend and the user should see it.

### 6.7 Recurring detection

Run a nightly `WorkManager` job (not on the ingest path). Group by `(counterparty_norm | vpa | tail+amountBand)`, look for ≥3 occurrences with a consistent gap (monthly ±4 days, weekly ±1 day, quarterly ±7 days). Create an unconfirmed `recurring_series` and surface it: *"Looks like ₹499 to Netflix every month. Track it as a subscription?"*

Confirmed series power: upcoming-cashflow projection, "you paid twice this month" alerts, and a "subscriptions you forgot" screen — which is, empirically, the feature people screenshot and share.

A missed expected occurrence (`next_due_date + 5` with nothing matched) increments `missed_count` and, at 1, notifies *"Your ₹499 Netflix payment hasn't shown up."* At 3, auto-pause the series rather than nagging forever.

---

## 7. What SMS can never tell you

Be honest about these in the product, not just in this document. Every one of them is a place where a lesser app lies.

| Blind spot | Why | Mitigation |
|---|---|---|
| **No MCC.** | Merchant category lives in the card-network auth message, not the handset. | The cascade. Accept `misc.unknown_merchant` as a legitimate terminal state. |
| **Basket contents.** | `AMAZON ₹4,320` could be nappies, a laptop, or both. | Honest label `shopping.ecom_mixed`. Offer split-transaction. Never guess "Electronics". |
| **Cash after withdrawal.** | ATM withdrawal → a virtual `CASH` account. Where it went is invisible. | `cash.cash_spend` manual entry with a fast "log cash" sheet; the honest plug is `cash.cash_unaccounted`, shown as its own line, never distributed across categories. |
| **Banks that don't SMS.** | Some accounts/cards send nothing, or only above a threshold. | Reconciliation drift detection (§6.5) surfaces it. Offer statement import for that account. |
| **Sub-threshold transactions.** | Many banks suppress alerts under ₹100 / ₹5,000. | Same: drift detection tells the user which account is incomplete. Say it plainly on the account card: "This account may be missing small transactions." |
| **P2P intent.** | `₹3,000 to 9876543210@ybl` — rent? loan repaid? dinner split? | Ask once, learn forever. `counterparty_label` + user rule. |
| **Split/shared expenses.** | The SMS is your full payment even when four people owe you. | Manual "split" that creates a receivable; out of scope for v1, note it. |
| **Foreign currency and markup.** | The forex markup arrives days later as a separate SMS. | Link by proximity + `fees_charges.forex_markup`; show it attached to the original transaction. |
| **Pending vs settled.** | A hold is SMS'd, then settles at a different amount. | Dedup weak key + amount tolerance; if a settle arrives with a different amount and matching ref, update the original rather than adding a second row. |
| **Deleted/expired SMS.** | Users clear their inbox; some OEMs prune. | Backfill is best-effort. Say so in first-run: "We found 4 years and 2 months of history." Never imply completeness you can't verify. |
| **Dual SIM / forwarded messages.** | A message on SIM2 or forwarded from a family member's phone. | Store `subscriptionId`; offer per-SIM enable. Reject MSISDN senders (§4.4), which kills forwards. |
| **Which of two identical cards.** | Two cards from the same issuer ending in the same 4 digits. | Rare; when detected, ask the user to name them. Do not guess. |

**The product rule that follows from this table:** the app's headline number is always accompanied by a completeness indicator. Not a disclaimer buried in Settings — a visible, tappable *"Based on 312 of 312 messages · HDFC matched ✓ · ICICI drift ₹1,240 →"*.

---

## 8. Screens and first-run flow

### 8.1 First run

1. **Value first, permission second.** One screen explaining what the app does, with a real screenshot of a populated ledger. No permission request yet.
2. **Prominent disclosure**, full screen, before the system dialog (copy in §9.4). Two buttons: "Continue" and "Not now". "Not now" must lead to a working app (manual mode), not a dead end.
3. **System permission dialog** for `RECEIVE_SMS` + `READ_SMS`.
4. **Backfill with visible progress**, then the reveal: *"Found 2,847 transactions across 3 accounts since Jan 2022."* This moment is the product.
5. **Account confirmation.** Show discovered accounts (issuer + tail), let the user name them, mark card vs bank, and archive any that aren't theirs.
6. **Inbox triage sprint.** Present the top 10 unknown counterparties by total value, not by recency. Ten taps categorise a large share of history. Show the running impact: *"You've sorted ₹47,000 of ₹61,000."*
7. **Done.** Land on Home with real numbers.

### 8.2 Screens

- **Home** — month-to-date Spend (the honest number), a completeness chip, the category donut (`ScoreRing` relabelled), upcoming bills, recent transactions, and the grey "Unsorted" slice if non-empty.
- **Ledger** — keyset-paged list, filters (account, category, flow type, date range, amount band, needs-review), sort. Clone `feature/history/`'s filter+sort affordances.
- **Inbox** — the review queue. One card per transaction, three suggested categories as chips, "Not a transaction" and "Exclude" as first-class options. A visible count badge in the bottom bar. **This screen is the trust engine; give it the best interaction design in the app.**
- **Transaction detail** — amount, account, merchant, category, **"Why this category?"** showing `evidence[]` and `classificationSource` in plain language, split, exclude, note, and the edit history.
- **Insights** — monthly trend (`ScoreTrendChart`), per-category sparklines, budget-vs-actual (`BrandMeter`), subscriptions, needs-vs-wants, savings rate.
- **Accounts** — per-account balance, reconciliation status and drift, wallet `treatTopUpAsSpend` toggle, card statement/due days, archive.
- **Settings** — SMS ingestion on/off (which unregisters the receiver, not a silent gate), rescan messages, FLAG_SECURE toggle (default ON), export CSV, contacts matching (default OFF), "help improve categorization" (default OFF), delete all data.

---

## 9. Google Play compliance plan

### 9.1 The policy position, stated precisely

- **The exception:** policy 10208820 lists "SMS-based money management" with the example *"apps that track and manage budget"*, covering `READ_SMS`, `RECEIVE_MMS`, `RECEIVE_SMS`, `RECEIVE_WAP_PUSH`. Present on the live page as of 2026-09-23 and in the preview policy effective **27 January 2027** (17225965), unchanged.
- **The framing you must satisfy:** the exception is temporary and premised on there being currently no alternative method to provide the functionality; exceptions are granted **case-by-case**.
- **The prohibition that shapes your architecture:** policy 16558241 (and preview 16909972) — you may not use alternative methods, including other permissions, APIs or third-party sources, to derive data attributed to Call Log or SMS related permissions.
- **The listing requirement:** 10208820 — make sure the app's description prominently documents and promotes its core feature(s).
- **If you don't qualify**, the policy is explicit that the permissions must be removed from the manifest.
- **Timeline expectation:** the declaration help page (9214102) states the request may require up to several weeks to process. There is no published SLA for policy appeals; any number quoted elsewhere is an estimate.
- **Not a blocker:** the July 2026 announcement (17134731) about removing `READ_CALL_LOG` account-verification — that is a Call Log row, replacements named as the Digital Credentials API and SMS Retriever API, and the live policy still carries the row today. **Its deadline is 27 January 2027, not August 2026.** It does not touch the money-management row.

**[UNVERIFIED]** Whether this exception has survived every SMS tightening cycle since 2019 — I have confirmed it survives into the January 2027 preview and nothing earlier. Do not repeat a longer claim.

### 9.2 Manifest permissions and the declaration

Declare exactly the four permissions in §4.1 (of which two are from the SMS group). Every additional sensitive permission is a separate argument you must win. **Strip `QUERY_ALL_PACKAGES`** if you copy any manifest fragment from DigiKavach; a budgeting app has no justification for it and it will fail review.

The Permissions Declaration form asks for: the permission requested, the core functionality it enables, a description of how it is used, **a video demonstration** (the page states you must provide one; YouTube link preferred, or a cloud-storage link to an mp4 or other common video format), and — if core functionality is behind sign-in — instructions to access that restricted content. Confirmation checkboxes and a multi-APK exception path exist.

Do not paraphrase the form's requirements from memory when you fill it. Open 9214102 and follow the seven steps as written.

### 9.3 Declaration form content — draft answers

**Core functionality:** *"The app's core and only purpose is to build a personal expense and income ledger for the user from the bank, credit-card and UPI transaction alert SMS that their own banks send to their own device. The app reads these messages on-device to extract amount, date, account, and merchant, and presents them as a categorised ledger with budgets and reconciliation."*

**Why the permission is required:** *"There is no alternative method to obtain this data. Indian banks deliver transaction alerts exclusively by SMS to the account holder's registered mobile number. There is no consumer-accessible API that returns these alerts. RECEIVE_SMS is required to record a transaction at the moment it happens; READ_SMS is required once, at setup, to build the user's transaction history from alerts that already exist in their inbox. Without both, the app has no data and no function."*

**Data handling:** *"All parsing and categorisation happens entirely on-device. No SMS content, no message body, and no message metadata is transmitted off the device, at any time, for any purpose. The app stores only the extracted transaction fields (amount, date, masked account tail, merchant name, category) in a local encrypted SQLCipher database, plus a 16-byte hash of each message used only to avoid recording the same transaction twice. Message bodies are never stored. The app has no account system and no server that receives user data."*

**Video demonstration — shot list:**
1. Fresh install, first-run screen stating what the app does.
2. The full prominent-disclosure screen, read on camera, showing both "Continue" and "Not now".
3. The system permission dialog and the grant.
4. Backfill running, then the populated ledger with real transactions.
5. A live incoming bank SMS producing a ledger entry within seconds.
6. The Inbox: correcting a category, and the resulting rule.
7. Settings: SMS ingestion off → the app visibly stops ingesting; delete all data.
8. Airplane mode on, a new SMS still categorised — demonstrating on-device-only processing.

Keep it under four minutes, no music, no marketing. A reviewer needs to see the feature work, not be sold to.

### 9.4 Prominent disclosure copy

Shown full-screen, before the system dialog, dismissible only by an explicit choice:

> **This app reads your bank SMS to build your expense ledger**
>
> To track your spending automatically, [App] needs permission to read the transaction alert messages your banks send to this phone.
>
> **What we read:** messages from registered bank, card and UPI senders — amount, date, account number ending, and merchant.
> **What we ignore:** OTPs, promotional messages, and everything from personal numbers. We never read your personal conversations.
> **Where it goes:** nowhere. All processing happens on this device. Your messages and your transactions are never sent to us or anyone else. We have no server that receives your data.
> **What we store:** the extracted transaction details, in an encrypted database on this phone. We do not store the text of your messages.
>
> You can turn this off at any time in Settings, or use the app by entering transactions yourself.
>
> [ Continue ]  [ Not now ]

### 9.5 Data Safety answers

Google's rule is that data processed entirely on-device and never transmitted does not count as collected or shared (10787469). For an on-device-only build:

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| SMS or MMS | Not collected (processed on-device only) |
| Financial info — purchase history | Not collected (processed on-device only) |
| Is data encrypted in transit? | N/A — no data leaves the device |
| Can users request data deletion? | Yes — Settings → Delete all data |
| Data collected for advertising/analytics? | No |

If you later add crash reporting or analytics, this table changes and the declaration must change with it. Keep the v1 build genuinely zero-collection; it makes every other conversation easier.

**The Financial features declaration (13849271) is mandatory for every published app**, including closed and open testing tracks. Budgeting/expense tracking is **not** one of its listed categories (personal loans, loan facilitation, payday loans, banking, line of credit, EWA, microfinance, wallets, transfers, BNPL, crypto, stock trading, crowdfunding, credit monitoring, financial advice, insurance, other). So your answer is almost certainly "none of these". It is a form to complete, not a gate — but it must stay consistent with a store listing that talks loudly about bank SMS and UPI.

### 9.6 Store listing — write it before you file

The listing must prominently document and promote the SMS feature. Not a footnote.

- **Title:** include the mechanism, e.g. "… — SMS Expense Tracker".
- **Short description:** lead with "Reads your bank SMS to track spending automatically. All on-device."
- **Long description, first paragraph:** what it reads, what it ignores, and that nothing leaves the phone. Then features.
- **Screenshots:** include the disclosure screen and the ledger. A reviewer scrolling the listing should see the SMS feature before anything else.
- The one genuinely documented failure mode is a listing that hides the SMS feature while the declaration claims it is core. Do not create that mismatch.

### 9.7 DPDP (India) — real law, not a Play gate

The DPDP Rules were notified 14 Nov 2025. Consent-manager registration and Board penalty powers commence **13 Nov 2026**; full substantive compliance (notice, consent, rights, retention, transfers, breach reporting) is due **13 May 2027**. Penalties scale to ₹250 crore. These are genuine obligations that shape your consent UX and your privacy policy — but Google does not check them at review. An on-device-only architecture shrinks this surface to nearly nothing, which is a second reason not to build a cloud parser.

### 9.8 The fallback ladder if rejected

Ordered, and pruned of the options that are themselves violations.

1. **Read the rejection and fix the obvious.** Most first rejections are listing mismatch, an unrelated permission tagging along, a video that doesn't show the feature, or a reviewer who couldn't reach it. Fix and resubmit. Note: Play allows **one appeal per enforcement action**, so the first submission should carry the whole argument.
2. **Strip `READ_SMS`, keep `RECEIVE_SMS`.** You lose backfill; you keep realtime. Replace backfill with statement/CSV import. This is a real product downgrade but a much smaller ask.
3. **Ship the non-derivative mode as the product.** Manual entry + **share-to-app** (the user shares an SMS into your app from their messaging app — user-initiated, per-message, not automated) + CSV/PDF statement import. This is a legitimately different data path, not SMS-derivation with extra steps.
4. **Account Aggregator (RBI AA framework).** The sanctioned, consented route to actual bank data. Requires an FIU relationship and is a business project, not a weekend. Worth understanding as a v3 direction. **[UNVERIFIED]** — no evidence Play review weighs AA's existence when adjudicating this permission, so do not assume its existence hurts your declaration either.
5. **Not on the ladder: `NotificationListenerService`.** Automated scraping of bank notifications to build the same ledger is deriving SMS-attributed data, which 16558241 prohibits outright. There is no declaration form for notification access, so you get no review signal before shipping — the exposure is post-publication enforcement with one appeal. Additionally, Android 16 has Android System Intelligence parse and redact OTP codes before they reach third-party listeners in high-risk scenarios; that targets OTPs more than transaction alerts today, but the direction of travel is against notification scraping. Do not build this.
6. **Not on the ladder as a plan: sideloaded APK distribution.** India is **not** in the 30 Sept 2026 developer-verification rollout (Brazil, Indonesia, Singapore, Thailand are), with global expansion in 2027. An India APK works today and probably not through 2027. It is a bridge, never a strategy.

---

## 10. MVP scope and an honest solo-dev timeline

Assumes one experienced developer, part-time-to-full-time, with the DigiKavach codebase available. Weeks are calendar weeks of real work, and they do **not** include Play review waiting, which runs in parallel.

### v1 — "It shows me my real spending" (10–14 weeks)

| Block | Weeks | Contents |
|---|---|---|
| Foundation | 1.5 | Extract `:core-crypto` + `:core-ui` library modules from DigiKavach. New project, manifest (allowBackup=false, four permissions), signing config, versionCode from commit one, no Firebase, no google-services.json. |
| Ingestion | 1.5 | `SmsReceiver` + recovered manifest block, ingest queue, backfill worker with FGS + progress, share-target activity. |
| Gate + parser | 2.5 | Normaliser, sender trust, rule bundle loader, ~40 rules covering HDFC/SBI/ICICI/Axis/Kotak/PNB/BoB + SBI Card/HDFC Card/Amex + PhonePe/GPay/Paytm/CRED. Dedup. Reject/route table. |
| Ledger core | 2 | Room + SQLCipher, accounts, postings, the zero-sum invariant, transfer pairing, card-bill conditional, account discovery. |
| Cascade v1 | 2 | Stages 0–5 (no model). ~800-entry merchant dictionary + ~2,000 aliases. User rules + learning loop. |
| UI | 2 | Home, Ledger, Inbox, Transaction detail, Accounts, Settings, first-run + disclosure. Reuse Charts.kt and Common.kt. |
| Compliance + polish | 1 | Listing copy, disclosure screen, declaration video, Data Safety, privacy policy, Financial features declaration. |

**Explicitly out of v1:** budgets, insights beyond a donut and a trend, the ML model, recurring detection, bills, splits, multi-currency, widgets, export beyond CSV.

### v2 — "It's accurate and it warns me" (+6–8 weeks)

Recurring detection and subscriptions · bills + matching · reconciliation UI with drift diagnostics · budgets + budget-health colour band · insights (needs-vs-wants, savings rate, month-over-month) · the Stage 6 model trained on real corrections · dictionary grown to ~3,000 merchants · statement import (CSV, then PDF) · Hindi + one South Indian language, **actually shipped** (see traps).

### v3 — "It's a financial picture" (+8–12 weeks)

Split transactions and receivables · net-worth view with investment positions · multi-device sync (and the encrypted-backup design that goes with it — this is where the crypto gets hard, do not rush it) · goal tracking · Account Aggregator exploration · widgets and a quick-add tile.

**Honest note on the timeline:** the parser and the dictionary will take longer than budgeted. They always do, because the long tail of bank templates is discovered, not designed. Treat the week counts for "Gate + parser" and "Cascade v1" as floors. The rest are reasonable.

---

## 11. Risks, kill criteria, and open decisions

### 11.1 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Play declaration rejected repeatedly | High | Listing written first; minimal permissions; on-device-only; strong video. Fallback ladder §9.8. One appeal per action — make the first submission complete. |
| Personal Play account's 12-testers × 14-days gate | Medium | Register as an organization if at all possible. Otherwise start the closed test on week 6, not week 13. |
| Parser accuracy plateaus below usefulness | High | §12's corpus and measurement plan, run from week 3 — not at the end. |
| Silent wrong numbers destroy trust | **Critical** | Confidence bands with a visible "I don't know" state; reconciliation drift surfaced; completeness chip on Home. |
| `AEADBadTagException` / silent history loss on device transfer | High | `allowBackup=false` in commit one; decrypt failure raises a blocking error, never `getOrDefault(emptyList())`. |
| Copying DigiKavach's manifest wholesale | Medium | Write the new manifest by hand. Do not inherit call screening, FileGuard, `QUERY_ALL_PACKAGES`, or the notification listener. |
| Copying `SmsScanReceiver` including its premium gate | Medium | The gate at line 46 silently disables ingestion. Delete it. The donor repo's own test suite exists because this shipped as a bug. |
| Three-way manual port across v2 / Lite / ledger | Medium | Extract library modules before starting. |
| DPDP obligations from 13 May 2027 | Medium | On-device-only keeps the surface minimal. Revisit if you ever add sync. |

### 11.2 Kill criteria

Stop or pivot if any of these is true after an honest measurement:

- **Extraction accuracy on the top-10-bank corpus is below 95% on amount and direction** after two iterations of rule work. Below that, the ledger cannot be trusted and no amount of UI fixes it.
- **More than 25% of transactions land in the Inbox after the user has triaged their first 50.** The learning loop isn't working; the cascade is wrong, not undertrained.
- **Reconciliation drift on the developer's own primary account exceeds 2% of monthly spend for two consecutive months.** Your own phone is the easiest possible test case.
- **Two full rejection cycles with no actionable feedback and no path through the fallback ladder.** At that point the product is the non-derivative mode, and you should decide whether that product is worth building.

### 11.3 Open decisions — the user must choose before week 1

1. **Play account type.** Personal (12 testers × 14 days of continuous closed testing before production) vs organization (exempt). This decision costs two weeks of serial delay, is independent of SMS, and is the cheapest thing on this list to get right.
2. **The non-SMS mode's identity.** Manual + share-to-app + statement import. Confirm you will **not** build a notification listener fallback, and write that decision down where a future you will find it.
3. **On-device only, permanently?** On-device lets you declare "not collected", shrinks DPDP, and avoids the data-sale prohibitions entirely. Any cloud parsing buys three ongoing obligations. Recommendation: on-device only through v2, revisit only for sync in v3.
4. **Library module extraction — now or never.** Extract `:core-crypto` and `:core-ui` before the first ledger commit, or accept a permanent three-way port tax.
5. **Dictionary sourcing.** Hand-curated (slow, accurate, yours) vs seeded from an open dataset (fast, licence questions, unknown quality). This determines whether Stage 1 hits 60% or 30% on day one.
6. **Monetisation, decided before the taxonomy ships.** If some categories or insights become paid, that must never gate *ingestion* — DigiKavach already proved what happens when it does.
7. **Languages.** If you ship Hindi/Tamil/Telugu, budget the string work in v2 and **actually wire `locales_config.xml` and drop `resourceConfigurations += listOf("en")`** — the donor repo built four translations and stripped them from the APK.

---

## 12. Test corpus and accuracy measurement

### 12.1 The corpus

Build `sms-corpus.jsonl` from day one, before the parser. Each line:

```json
{
  "id": "hdfc-upi-debit-001",
  "sender": "VM-HDFCBK-S",
  "body": "Sent Rs.450.00\nFrom HDFC Bank A/C x0601\nTo SWIGGY\nOn 14/09/26\nRef 526312345678\nNot You? Call 18002586161",
  "receivedAt": 1789382400000,
  "expect": {
    "isTransaction": true,
    "amountPaise": 45000,
    "direction": "DEBIT",
    "issuerId": "HDFC",
    "instrument": "ACCOUNT",
    "tail": "0601",
    "rail": "UPI",
    "valueDate": "2026-09-14",
    "refNo": "526312345678",
    "counterpartyRaw": "SWIGGY",
    "flowType": "SPEND",
    "categoryId": "food_dining.delivery"
  }
}
```

**Sources, in order of value:**
1. **Your own inbox**, exported and hand-labelled. 500–1,500 real messages. This is the highest-value dataset you will ever have and it costs one afternoon.
2. **Synthetic variants** of each template: amount edge cases (`1,00,000.00`, `150.0`, `₹9`, `Rs 1,23,456.78`), date formats, multiline vs single-line, the helpline-number trap, negation (`has not been debited`), Unicode obfuscation.
3. **Adversarial negatives** that must be rejected: OTPs, promos with `-P` headers, MSISDN-sender fakes, declined-transaction alerts, bill-due statements, mandate pre-debits, balance-only messages.
4. **Friends and family**, with explicit consent, sender-anonymised. Do not scrape anything.

Target: **≥ 2,000 labelled messages before v1 ships**, covering at minimum HDFC, SBI, ICICI, Axis, Kotak, PNB, BoB, Canara, IDFC First, Yes, plus SBI Card, HDFC Card, Amex, plus PhonePe, GPay, Paytm, CRED, Amazon Pay.

### 12.2 The harness

A JVM unit test (no device, no emulator) that runs the whole gate + cascade over the corpus and fails the build on regression:

```kotlin
class CorpusAccuracyTest {
    @Test fun `extraction meets thresholds`() {
        val r = runCorpus("sms-corpus.jsonl")
        assertThat(r.amountAccuracy).isAtLeast(0.99f)       // exact paise
        assertThat(r.directionAccuracy).isAtLeast(0.995f)
        assertThat(r.isTransactionF1).isAtLeast(0.98f)
        assertThat(r.falsePositiveRate).isAtMost(0.005f)    // non-txn scored as txn
        assertThat(r.flowTypeAccuracy).isAtLeast(0.95f)
        assertThat(r.categoryTop1).isAtLeast(0.80f)
        assertThat(r.silentErrorRate).isAtMost(0.02f)       // THE ONE THAT MATTERS
    }
}
```

Run it in CI **before** the assemble step, the way the donor repo runs `testDebugUnitTest` before `assembleDebug` — a broken parser should fail in seconds, not after an eight-minute build.

### 12.3 The metrics that matter, in priority order

1. **Silent error rate** — transactions auto-posted at `confidence ≥ 0.75` that were wrong. This is the number that kills the product. Target **< 2%**, and treat any regression here as a release blocker regardless of every other number.
2. **Double-count rate** — rupees counted twice in the Spend total, measured by running the corpus through and comparing against hand-computed truth for a synthetic month containing a card bill, a SIP, a wallet top-up and a self-transfer. Target **0**.
3. **Amount + direction accuracy.** Target ≥ 99% / ≥ 99.5%. Below this nothing else matters.
4. **False positive rate** (non-transaction scored as transaction). Target ≤ 0.5%. A phantom transaction is worse than a missed one.
5. **Inbox rate** — share of transactions landing below 0.75. Target ≤ 25% cold, ≤ 10% after 50 user corrections.
6. **Category top-1 accuracy** on the auto-posted set. Target ≥ 80% cold, ≥ 92% after learning.
7. **Unknown-VPA auto-resolution rate** — share of repeat unknown VPAs resolved by a learned rule. This is the learning loop's health.
8. **Reconciliation match rate** — share of balance snapshots with `delta == 0`. This is the only end-to-end, ground-truth-from-the-bank metric you have. Target ≥ 90% of snapshots on accounts with full SMS coverage.
9. **Cascade latency p99** on a 2019-class device. Target < 15 ms.

### 12.4 In-the-wild measurement

Ship an on-device, local-only **"Accuracy" screen in Settings** (not analytics, nothing uploaded): number of transactions, share auto-posted vs inbox, correction count, per-account reconciliation drift, and the top 5 unresolved counterparties by value. It is a debugging tool for you on your own phone, a transparency feature for the user, and the honest answer to "how do you know it's right?"

---

## Appendix A — the traps, condensed

Print this and keep it next to the keyboard.

1. `SmsScanReceiver.kt:22`'s own KDoc says it is registered in the manifest. **It is not.** Recover the `<receiver>` block from `d90e7ff^` including `android:permission="android.permission.BROADCAST_SMS"`.
2. `ProtectionScreen.kt:141` requests a permission not in the manifest; Android denies instantly, `shouldShowRequestPermissionRationale()==false` then makes the app conclude "permanently blocked". 539 lines of UI wired to nothing. Fix the manifest first.
3. `resourceConfigurations += listOf("en")` strips every translation from the APK, and `locales_config.xml` is never referenced. Four languages built and thrown away.
4. `SmsScanReceiver.kt:46`'s premium gate silently disables ingestion. Delete it.
5. Every classification in the donor is a Retrofit round-trip. There is no offline path and no transaction parser on that server.
6. `allowBackup` defaults to **true**. A fresh manifest re-arms the `AEADBadTagException` fuse, and `getOrDefault(emptyList())` swallows it into silent total history loss.
7. `QUERY_ALL_PACKAGES` will fail review for a budgeting app. Strip it.
8. Do not inherit `ScamCallScreeningService`, `FileGuardService`, `CircuitBreakerService`, `BootReceiver`'s extra filters, or the notification listener.
9. `google-services.json` is load-bearing in the donor build. Remove the plugin and the Firebase deps together, or the build fails.
10. Copy `grantJustArrived()`'s transition semantics, not a state-based re-check, or guards become impossible to turn off.
11. `deviceId.fingerprint()` (ANDROID_ID) is sent with every scan in the donor. A ledger must not inherit that silently — and in an on-device-only build, nothing is sent at all.
12. Never pipe `gradlew` through `tail`/`head`; redirect to a file and grep for `BUILD SUCCESSFUL|BUILD FAILED|^e: `.
13. `JAVA_HOME=C:/Users/reddy/AppData/Local/Programs/jdk-17/jdk-17.0.19+10`, not Android Studio's bundled `jbr`.
14. Set `versionCode`/`versionName` properly from commit one. The donor shipped v1.0–v1.5 all reporting the same version and QA could not tell which build a bug was against.

# Data retention & respondent rights

Written for P0-7. Describes what Playverto stores about respondents, how long,
who can remove it, and the limits of what the platform can actually honour.

## What is stored about a respondent

Every Verto ends with an automatically appended demographic tail
(`DemographicQuestions`): birth month/year, where they live, and gender. So in
practice **every** Verto holds personal data, not just ones whose creator chose
to ask for it. Creators can additionally add two opt-in demographic questions
(`DemographicQuestions::OPTIONAL_CARDS`) — Heritage (ethnicity) and
Neurodiversity — from the add-question modal; those are stored only on Vertos
whose creator chose to ask.

A `responses` row can hold:

| Field | What it is |
|---|---|
| `answers` | Their answers, keyed by card index |
| `demographic_birth_year`, `demographic_gender` | From the demographic tail |
| `demographic_heritage`, `demographic_neurodiversity` | From the opt-in demographic questions, when the creator added them |
| `region_country`, `region_label` | Derived from the location answer |
| `locale`, `device_kind` | Language and rough device class |
| `started_at`, `completed_at`, `created_at` | Timings |
| `consent_agreed_at` / `consent_declined_at`, `consent_text_snapshot` | The consent record, including the exact wording shown |
| `score`, `quiz_max`, `token_totals` | Quiz and token scoring |
| `session_token` | A random per-session UUID minted in the browser |
| `respondent_code_digest` | HMAC of a code the respondent chose, if the creator enabled codes |

No email address, name or account is attached to a response. There used to be
one deliberate, creator-chosen exception — the **contact card**
(`contact_form`), which stored whatever the respondent typed into its name /
company / industry / email fields inside `answers`, like any other answer.
That card type has been **retired**: it can no longer be added to a Verto, the
player skips any copy left in a published deck, and the server refuses an
answer to one, so no response created from now on can carry identifying data
of this kind.

Details collected while the card was live are still held, in the `answers` of
the responses that carry them, and are still shown in that Verto's results and
CSV/Excel export to the creator who collected them. They ride the existing
respondent-data export and deletion paths (`/respondent-data`) like the rest of
the response, and go when the response or the Verto does. Retiring the card
stopped the collection; it did not delete what was already collected.

The `respondent_code_digest` is a one-way HMAC keyed per Verto
(`Survey#respondent_code_key`), so a code is comparable **within** one Verto and
nowhere else, and the plaintext is never stored, logged or returned.

### Recall, and what it changes

A `respondent_code` card can opt in to **recall** (`recall: true` on the card,
off by default). With it on, entering a code at `POST /play/:token/recall`
returns that identity's previously given answers **to ask-once questions only**,
so "asked once" holds across devices rather than only across visits to one
browser.

This is the one place the product reads a digest back rather than merely
grouping by it, and the digest's key is a code the respondent chose to be
memorable — which is to say guessable. So it is bounded on every side that can
be bounded (`RespondentRecall`, `PlayerController#recall`):

- off unless the creator turned it on, on the card itself;
- only cards *currently* flagged ask-once, and never a graded or token-awarding
  one;
- nothing else from the response — no demographics, region, locale, contact
  details, score, totals, timestamps or counts;
- a card whose stored answers **disagree** under one digest is dropped, on the
  assumption that two people invented the same code;
- one response shape for unknown code, blank code, recall off and nothing
  recallable, so the endpoint cannot be used to confirm that a code exists;
- three budgets: requests per IP, *distinct codes* per IP, and lookups per code.

The residual exposure, stated rather than implied: a correctly guessed code
returns that person's ask-once answers. A creator who does not need cross-device
ask-once should leave recall off, which is the default, and still gets wave
matching — that has never required reading anything back.

## Retention period

Responses are kept for the life of the Verto. Deleting a Verto deletes its
responses (`dependent:` on the association); archiving one does not.

`rake responses:purge[days]` removes responses older than N days across all
organisations, for a controller who wants a shorter horizon than "forever".
It is **not scheduled by default** — retention length is the customer's policy
decision, not ours, and silently deleting a funder's research data would be
worse than keeping it. Run it deliberately, or add it to `config/recurring.yml`
once a period has been agreed.

```
bin/rails responses:purge[365]          # delete responses older than a year
bin/rails "responses:purge[365,dry]"    # count them without deleting
```

## Subject access and erasure

Admins get **Results → Download CSV → One respondent's data…**
(`/surveys/:id/respondent-data`), which:

- finds a respondent's rows by session token or by respondent code;
- exports **everything** held about them as JSON (Article 15 / 20) — including
  the demographics, consent record, derived region, device, timings and scoring
  that the ordinary results export leaves out;
- erases those rows permanently (Article 17).

Erasure is a hard delete, not an anonymisation pass. A stripped-but-present row
would still be personal data if it could be re-linked, and the right is erasure.
The consequence is honest: response counts drop, and any cached summary or
report keyed to the old count regenerates the next time it is opened.

The creator is the data controller here. A respondent's request reaches them,
not Playverto, so this is a creator-facing tool rather than a self-service
portal.

## The limit worth knowing

**Most respondents cannot be identified after the fact.** The session token
lives in `sessionStorage`, keyed to the Verto's submit URL, and is gone when the
browser tab closes. Unless the creator enabled respondent codes — in which case
the respondent knows their own code — a person who comes back a week later has
no handle on their own row, and neither does anyone else.

This is a real gap in honouring Article 17 on request, and it is a deliberate
consequence of collecting no identifier. Closing it would mean either showing
respondents a receipt code at the end of a Verto that they could quote later, or
storing a durable identifier — which trades a privacy property for a rights one.
That is a product decision, not a bug fix, and it is not made here.

The `respondent_code` card narrows the gap where a creator uses it — a
respondent who chose a code has a handle on their own rows, and
`RespondentDataController` already accepts one — but it does not close it:
entering a code is required to proceed wherever the card or pre-screen
appears, yet the code is only as good as the respondent's memory, and
nothing stops a throwaway entry they can never reproduce.

## Related

- Consent enforcement: `Survey#default_consent_gate?` (P0-6)
- Small-cell suppression on public comparisons: `Response::MIN_REGION_SAMPLE_SIZE`
- Encryption keys backup: `PRODUCTION_READINESS_PLAN.md` P1-6

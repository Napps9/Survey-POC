# Active Record encryption keys — what they protect, and how to not lose them

**The five-minute task: copy three values out of Render into a secret store you
control. Everything else in this document is context or recovery.**

---

## What is encrypted

Two columns, both on `users`:

- `google_refresh_token`
- `google_access_token`

They grant write access to a user's Google Drive and Sheets, which is why they
are encrypted at rest. Nothing else in the database uses Active Record
encryption — checked with `grep -rn "^\s*encrypts " app/models/`.

## Why this is on the readiness plan

`render.yaml` declares the three keys as `generateValue: true`. Render mints
them **once** and keeps them stable for the life of **that service**. It does
not back them up, and they exist nowhere else — not in the repo, not in
`.env.example`, not in any credentials file.

So if the service is recreated, or its environment group rebuilt, Render
generates three new values. The database is untouched, and every stored token in
it becomes permanently undecryptable. There is no recovery from that except a
copy of the original keys.

## What actually happens if they are lost

Verified rather than assumed — write a token under one key, boot under another,
read it back:

```
google_connected? -> RAISED ActiveRecord::Encryption::Errors::Decryption
```

`User#google_connected?` is called from `app/views/surveys/index.html.erb` — the
**dashboard**. So before the guard described below, losing the keys did not just
break Google export: it 500'd the app's home page for every affected user,
including the page they would have used to reconnect.

**That specific outcome is now prevented.** `google_connected?` and
`google_refresh_token_if_readable` treat an undecryptable token as "not
connected", report it to Sentry, and let the user reconnect — which overwrites
the unreadable value. Losing the keys is now a *degradation* (everyone
re-authorises Google) rather than an outage.

That is a safety net, not a substitute for the backup. Take the backup.

---

## The backup (do this once)

1. Render dashboard → the `playverto` service → **Environment**.
2. Copy the values of all three:
   - `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
   - `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
   - `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`
3. Store them somewhere **you** control and that survives the Render account —
   a password manager entry, or a sealed secret in whatever the team already
   uses. Not a note in this repo, and not a chat message.
4. Verify the copy without exposing it (below).

## Verifying a backup without exposing it

On the server:

```
bin/rails encryption:fingerprints
```

It prints the first 12 hex characters of the SHA-256 of each key — one-way, and
far too little to reconstruct a key from. Run the same hash over your stored
copy; the three pairs must match.

To check the keys still match the *data* rather than each other:

```
bin/rails encryption:verify
```

It counts how many stored tokens fail to decrypt and exits non-zero if any do.
It never prints a token or a key.

---

## Rotating the keys

Supported, and tested. Reading falls back through previous keys, so there is no
re-encryption window:

1. Put the **current** primary key in `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEYS`
   (comma-separated; more than one generation is fine).
2. Set the new value in `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`.
3. Deploy. Rows written under the old key keep decrypting; anything written from
   now on uses the new key.
4. `bin/rails encryption:verify` should report zero undecryptable.
5. Leave the old key in `PREVIOUS_KEYS` until every row has been rewritten. For
   these two columns that means every user reconnecting Google, so in practice:
   leave it.

Wiring note, because it cost a boot failure to find: the previous-key providers
are built in `config/initializers/encryption_previous_keys.rb`, not in
`config/application.rb`. `DerivedSecretKeyProvider` derives its key **in the
constructor**, from `key_derivation_salt` on the global encryption config, and
that config has not been applied while `application.rb` is still running.
Building it there raises `Missing Active Record encryption credential` at boot.

## If they are already lost

1. Check for a copy first — Render support may retain prior env values, and the
   keys may exist in a previous deploy's shell history or a teammate's store.
2. If a copy is found, put it in `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEYS` and
   deploy. The data becomes readable again immediately.
3. If not, the tokens are gone. Clear them so nobody is left holding a token
   that cannot be used and cannot be seen:

   ```ruby
   User.where.not(google_refresh_token: nil).find_each(&:disconnect_google!)
   ```

   Every affected user then reconnects Google from the dashboard, which is the
   normal flow. No survey data, response, or account is affected — the blast
   radius really is these two columns.

# Mockups

Design documents, not code. Each directory is one self-contained `index.html` —
artboards with numbered callouts, keyed to a numbered spec at the foot of the
same page, so the pictures and their technical implications stay together. All
of them work from `file://`: fonts are base64-embedded, artwork is inline SVG,
and nothing is fetched.

| Deck | What it covers | Built? |
|---|---|---|
| [`responder-share/`](responder-share/) | A respondent passing a Verto on to friends and family — the end-screen share card, the link as it unfurls in WhatsApp, Messages and the feeds, the generated 1200×630 image, and where the creator writes the narrative headline. | No — except §4 (the `robots.txt` change), which shipped |
| [`responder-accounts/`](responder-accounts/) | A respondent taking an **account** at the end of a Verto — the Vertos they played, their answers against everyone, a token wallet, the impact the Verto had, follow-ups, and the emails. | No |

The two share a fiction (Haverley Town Council, "Car-free High Street", 1,284
responses) and cross-reference each other's specs, so they read as one story —
read `responder-share/` first.

Each deck carries its own README with the board list, how to re-shoot the PNGs,
and how to rebuild its PDF.

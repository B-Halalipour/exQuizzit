# exQuizzit — Personal rebuild

A fresh country-flag game built for Behnoud Halalipour's portfolio. The original Northcoders team project and Git history remain in the repository root. This independent implementation lives in `docs/`.

**Play:** https://b-halalipour.github.io/exQuizzit/

## Features

- 78 bundled SVG country flags, four shuffled choices, and 10 unique questions per round.
- Three paces: Explorer (30 seconds), Adventurer (20 seconds), Expert (10 seconds).
- Server-checked answers, question deadlines, speed bonuses, and retry-safe answer submission.
- Guest play with a public leaderboard; optional Supabase email/password accounts.
- Personal best and round totals on the current device.
- Keyboard shortcuts 1–4, accessible controls, responsive layout, reduced-motion support.

## Run locally

Serve this folder with any static HTTP server, for example `python3 -m http.server 4173 --directory docs` from the repository root. No frontend dependencies or build step.

## Database setup

Run `database.sql` in a Supabase SQL editor. Update the public project URL and publishable key at the top of `app.js`. **Never add a database password or service-role key to the frontend.** The schema creates only `exq_` prefixed objects and does not modify the original News app tables.

The game tables have row-level security and no direct anonymous access. Four limited RPC functions create a round, return its current question, validate an answer, and return the top 20 completed scores. Correct answers and scoring remain in Postgres. Only display name, score, accuracy, pace, and finish time appear on the leaderboard. Guest round IDs are capability tokens: do not share an active round's ID. For a high-traffic production deployment, add rate limiting and bot protection.

Enable email/password sign-in in Supabase Auth. Set the Auth Site URL and allowed redirect URL to the deployed game URL. Account creation uses email confirmation if enabled. Guests can play immediately. Signed-in rounds are associated with the authenticated user. The current device stats remain local.

## Hosting

GitHub Pages: deploy from the `main` branch, `/docs` folder. All frontend assets including flags are bundled; Google Fonts are optional and fall back to system fonts. The database is hosted separately on Supabase's free plan, which may pause with inactivity.

## Credits

Original exQuizzit concept and team project: Behnoud Halalipour, Jake Daniels, Brad Mattison, Joel Kram. This version is a fresh implementation prepared for Behnoud's personal portfolio, with AI assistance. Flags sourced from [Flagcdn](https://flagcdn.com/) (country flags are public-domain symbols; source SVGs are bundled in `flags.js`). Fonts: Space Grotesk and DM Sans via Google Fonts.

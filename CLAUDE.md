# Comptroller Intelligence Agent — Project Brief

## What this is
An executive financial intelligence dashboard for Sean (CEO, Lead Ventures) covering his portfolio companies. Built by Dr. Danielle Jennings. Currently a single self-contained `index.html` deployed to Netlify. This project is mid-migration from a localStorage prototype to a Supabase-backed application.

## Current state (v2)
- Single-file app: all CSS, markup, and JS in `index.html`. No build step, no dependencies. Deployed by dropping the file into Netlify.
- Companies are 100% user-created (nothing prebuilt). Add/Edit/Delete via a dialog; "+ Add Company" pill in the company switcher; Edit/Delete tools in the Company Detail Workspace header.
- Documents are uploaded per-company via the Upload Center. Only metadata persists (company, type, name, amount, note, filenames, date) — actual files are NOT stored yet.
- Shared Views: named presentation filters (localStorage key `cia-views-v1`, active view `cia-active-view`). Each view selects included companies and visible panels (insights / comparison table / documents). Presenting hides all editing controls, the Upload Center, and the Views button; the rollup pill takes the view's name and aggregates only included companies. IMPORTANT: this is presentation-level filtering only, NOT security — real per-person access requires Auth + RLS (roadmap phase 3). Saved views should become permission templates in that system.
- AI Executive Insights has a priority legend (Red = critical/act immediately, Amber = attention this cycle, Green = healthy/optimize).
- Risk Heat Map severities are currently illustrative (seeded from company risk score). Early build-out task: map each tile to real data (Cards → credit utilization, 60+ → aged obligations, etc.).
- Persistence: localStorage keys `cia-companies-v1`, `cia-documents-v1`, `cia-views-v1`, `cia-active-view`, `cia-theme`.
- "Lead Ventures Overall" is a computed rollup, not stored data.
- Derived metrics (formulas are shown to users in the drill-down modal — keep them transparent):
  - profit = revenue − expenses
  - workingCapital = cash − obligations (60+ day)
  - health = clamp(55 + margin×80 − debtRatio×18 − max(credit−30,0)×0.35, 20, 98)
  - riskScore = clamp(debtRatio×35 + credit×0.45 + oblRatio×30, 4, 96); High ≥55, Medium ≥32
  - confidence = 45 + 12 per uploaded document, cap 95
- Charts are hand-rolled SVG (no chart library): smooth curves, gradient area fills, data derived from company figures via seeded deterministic series. Trend curves are illustrative until historical data exists.
- Dual theme: dark (default, champagne gold #D9AB52 accent) and light (bronze gold #A97F2C). Theme-aware chart palettes live in the `PALETTES` object in JS; CSS themes via `[data-theme="light"]` variable overrides. Any new color must exist in both themes.
- Login screen is a placeholder — email only, no password, no real auth.
- Fully responsive: single-column stacking on mobile, sticky first table column, horizontally scrolling company switcher. Sean uses this on his phone — test every change at mobile widths.

## Known gaps (good first tasks)
- Document records have no edit/delete/replace once added.
- No statement history concept — a new month's statement has no relationship to the prior one (needs dates + "latest per account" once Supabase exists).
- Heat map tiles not yet wired to real category data.
- Divisions within companies do not exist in the data model — add a `divisions` sub-table in the Supabase schema so Shared Views can filter at division level, not just company level.

## Design system (do not drift from this)
- Fonts: IBM Plex Sans (UI), IBM Plex Mono (all numerals, KPIs, tables, chart labels).
- Executive terminal aesthetic: dark ink navy, gold accent rules on panel tops, tinted pills (never solid color blocks) for risk/priority.
- CSS variables for all colors. No frameworks. No Tailwind. Keep it a single file until the Supabase migration forces structure.

## Roadmap (in order)
1. **Supabase data layer** — `companies` and `documents` tables replacing localStorage. Supabase project URL: https://reilvydggsivzwdunrrq.supabase.co (Danielle has admin credentials; ask her for keys — never assume).
2. **Real file storage** — private Supabase Storage bucket for uploaded statements; access via short-lived signed URLs only.
3. **Auth** — Supabase Auth (email + MFA) replacing the placeholder login. Row-level security on every table. Roles: Danielle and Sean admin; possible read-only roles later.
4. **AI document analysis** — Supabase Edge Function that sends uploaded statements to Gemini for extraction (balances, due dates, line items) and writes results back. This makes confidence scores and AI Insights real instead of heuristic.
5. **Divisions + real shared access** — `divisions` sub-table under companies; convert Shared Views into server-enforced permissions so partners log in and can only ever see their assigned companies/divisions.
6. **Historical snapshots** — monthly `financials` table so trend charts plot real trajectories instead of seeded series.
7. (Later) Bank feeds via Plaid.

## Security requirements (non-negotiable)
- NO API keys in client-side code. All Gemini/AI calls go through Edge Functions. (Other internal tools in this portfolio hardcode a shared Gemini key — do NOT copy that pattern here; this app holds financial statements.)
- Private storage bucket + signed URLs; never public file links.
- RLS policies on all tables before any real data enters.
- Audit log table (who uploaded/viewed/deleted what, when) built early, not retrofitted.
- No real financial documents in the app until auth is live.

## Working conventions
- Deploy target is Netlify; keep zero-setup for non-technical users (Sean must never need a terminal).
- Danielle iterates by deploying and testing in real environments. Ship working increments; don't hold changes for big-bang releases.
- When she corrects a formula, threshold, or interpretation, implement her definition exactly — don't substitute generic versions.
- Preserve all existing IDs, drill-down behavior, sorting, filtering, and the company add/edit/delete flow unless a change is explicitly requested.
- Clipboard API silently fails in sandboxed environments — always add visible fallback feedback for copy actions.

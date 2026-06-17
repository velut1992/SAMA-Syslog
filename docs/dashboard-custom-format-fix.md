# Runbook: Fix "shards failed — does not support custom formats" on Supra dashboards

**Supra Stack v3.6.0 — OpenSearch Dashboards**
**Audience:** Commissioning / Site team
**Severity:** Display-only (no data loss)
**Last updated:** 2026-06-17

---

## Symptom

Opening a Supra dashboard (e.g. the Syslog / Windows dashboard) shows a red error banner:

> **1 of N shards failed**
> `Field [CallingProcessCreateTime] of type [keyword] does not support custom formats`

(The field name may differ — any `*Time` or numeric field can trigger the same message.)

The data is **not lost**. This is a display-configuration conflict, not a pipeline or ingestion failure.

---

## Root cause

A field in the `supra-windows-*` index pattern has a custom **Date** format pinned to it,
but the field is stored as **`keyword`** (text) in the index. OpenSearch cannot apply a date
format to a keyword field, so it rejects the query on that index.

This typically surfaces **after a server restart**: a fresh daily index (e.g.
`supra-windows-2026.06.17`) is created and maps the field as `keyword` (per the Supra index
template, which deliberately stores most fields as keyword to avoid type-conflict rejections).
The previously-saved custom format no longer matches, so the dashboard query fails on the new
index.

> **One-time fix.** The custom format lives on a single shared object — the index pattern —
> not on each daily index. Once corrected it stays fixed across daily index rollovers.
> **There is no need to repeat this every day.**

---

## Prerequisites

- A Dashboards login with **admin** rights (able to edit Index Patterns / Saved Objects).
- Browser access to the Dashboards URL (the server, port **5601**), e.g. `https://<server-ip>:5601`.

---

## Part 1 — Targeted fix (the reported field)

1. Log in to **OpenSearch Dashboards** in the browser.
2. Click the **menu (☰)** in the top-left corner.
3. Scroll to **Management → Dashboards Management**
   *(in some builds this is labeled **Stack Management**).*
4. Click **Index Patterns** (may be labeled **Data Views**).
5. Open the pattern **`supra-windows-*`**.
6. In the field **search box**, type the field name from the error, e.g.:
   ```
   CallingProcessCreateTime
   ```
7. On that field's row, click the **edit icon (pencil ✏️)** on the right.
8. Find the **Format** dropdown — it is currently set to a Date format.
   Change it to **`- Default -`** (remove the custom format).
9. Click **Save field**.
10. Return to the dashboard and click **Refresh** (or reload the page).

✅ The "shards failed" error should now be gone and all data renders.

---

## Part 2 — Catch-all (recommended, prevents recurrence on other fields)

Any **other** field with a pinned custom Date/Number format will throw the same error on a
future restart. Clear them all in one pass:

1. Menu (☰) → **Management → Dashboards Management → Saved Objects**.
2. Search for `supra-windows` and find the **index-pattern** entry named `supra-windows-*`.
3. Click its name, then **Inspect**.
4. Locate the field **`fieldFormatMap`**. Every entry inside it is a pinned custom format.
   Remove the entries on time/number fields, **or** clear the whole `fieldFormatMap` value
   if no custom display formatting is required.
5. Click **Save object**.
6. Reload the dashboard.

> If unsure what to keep, clearing the entire `fieldFormatMap` is safe — it only affects how
> values are *displayed*, never the stored data.

---

## Verification

- Open the affected dashboard with the time range set to **the last 15 minutes** (live data).
- Confirm: **no red error banner**, panels populate, and the time histogram shows recent bars.
- Optionally open **Discover** on `supra-windows-*` for the last 24h to confirm documents are present.

---

## Rollback

This change only affects display formatting and is fully reversible:

- Re-open the field (Part 1, steps 5–8) and re-select the Date format, **or**
- In Saved Objects, restore the removed `fieldFormatMap` entry.

No data is modified at any point.

---

## Notes / Do-not

- **Do NOT** delete the index or reindex — it is unnecessary and would lose data.
- The Supra index template intentionally stores most fields as `keyword` to avoid type-conflict
  rejections; leaving these fields unformatted is the expected, supported configuration.
- If you want a particular timestamp field to be a *real* date (formattable, range-filterable),
  that requires a change to the index template (`supra-index-template.sh`) and carries a
  date-parsing risk — escalate to engineering rather than handling it on site.

---

*Supra Controls Private Limited — Supra Stack v3.6.0*

# Cleansing data files

Input files consumed by the sibling `*.sql` build scripts. Only synthetic examples are committed here — real input files (for example a company hierarchy you maintain) are supplied locally and must not be committed.

## Files

- **`company_hierarchy.example.csv`** — tiny synthetic company hierarchy (fictional company names) in the input format expected by [`../company_hierarchy_load.sql`](../company_hierarchy_load.sql). Includes one "comment typed into `child_5`" row to exercise the load fixup.

## Company hierarchy input format

UTF-8 CSV with a header row and exactly these eight columns:

```
date_col,parent_current,child_1,child_2,child_3,child_4,child_5,notes
```

Each row places one company in exactly one of `parent_current` / `child_1..5`; its ancestors are inferred from the nearest preceding rows at shallower depths (the loader forward-fills them). `date_col` and `notes` are free text.

## Preparing a real input file

1. Export the spreadsheet to CSV.
2. Transcode to UTF-8, trim every cell, and drop fully blank rows:
   ```bash
   python3 - <<'PY'
   import csv
   src = 'REPLACE-WITH-EXPORTED-PATH.csv'
   dst = 'docs/pdl_data_cleansing/data/company_hierarchy.csv'
   with open(src, encoding='cp1252', newline='') as f, \
        open(dst, 'w', encoding='utf-8', newline='') as g:
       r = csv.reader(f); w = csv.writer(g); next(r)
       w.writerow(['date_col','parent_current','child_1','child_2','child_3','child_4','child_5','notes'])
       for row in r:
           cells = [(c or '').strip() for c in (row + ['']*8)[:8]]
           if any(cells):
               w.writerow(cells)
   PY
   ```
   (Change `encoding='cp1252'` to match the export's encoding.)
3. Load it from the repo root:
   ```bash
   psql "$DATABASE_URL" -f docs/pdl_data_cleansing/company_hierarchy_load.sql
   ```

`data/company_hierarchy.csv` is the path the loader reads; keep it out of version control (add it to `.gitignore`). To try the routine on synthetic data, copy the example file to that path.

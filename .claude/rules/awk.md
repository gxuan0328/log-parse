---
paths:
  - "bin/**/*.sh"
  - "lib/**/*.sh"
---

# gawk conventions

Loaded when editing analyser scripts. The canonical examples are
`CORRELATE_AWK` (`bin/analyze_access.sh`), `IIS_AWK`
(`bin/analyze_iis.sh`), `ERROR_AWK` + `LIFETIME_AWK`
(`bin/analyze_errors.sh`).

## Header block on every awk program

```awk
# ----------------------------------------------------------------------------
# Purpose : one-line summary.
# Input   : how each record is shaped.
# Vars    : -v passes from the caller.
# Output  : TAB-prefixed kind tags, one per row.
# ----------------------------------------------------------------------------
```

## Emit TAB-delimited, kind-prefixed rows

Downstream bash should `grep TAG | awk '{print $N}'` without guessing
whitespace. Pattern:

```
TOTAL\t<n>
STATUS\t<code>\t<count>
ENDPOINT\t<uri>\t<count>
CLIENT_IP\t<ip>\t<count>
```

## Two-file joins: use `FILENAME == varname`, not `FNR == NR`

`FNR == NR` is standard but breaks when the first file is empty (FNR
resets and the second file is parsed as the first). Pass the first
file's path via `-v var=...` and compare `FILENAME == var`:

```bash
gawk -F'\t' -v api_file="$api_tsv" "$CORRELATE_AWK" "$api_tsv" "$app_tsv"
```

```awk
FILENAME == api_file { ... ; next }   # first file
{ ... }                                # second file
```

## Normalise before grouping

For top-N pattern reports, replace volatile tokens with placeholders so
semantically identical messages collapse into one key:

```awk
norm = msg
gsub(/[0-9]+\.[0-9]+ms/,           "Nms",  norm)
gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}/, "DATE", norm)
gsub(/[0-9]+/,                     "N",    norm)
error_count[norm]++
error_sample[norm] = msg     # keep one verbatim sample for display
```

Canonical reference: `ERROR_AWK` in `bin/analyze_errors.sh`.

## Sorting

- For `STATUS`-style raw emissions: let bash re-sort with `sort -t$'\t' -k3 -rn`.
- For `ENDPOINT` / `CLIENT_IP`-style "Top N" emissions: use
  `asorti(arr, sorted, "@val_num_desc")` inside the END block.

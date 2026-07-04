# BUG-030: GROUP BY output drops group-key column aliases and reorders columns

## Status: OPEN (2026-07-04) — upstream `67c4572d` (v0.3.0 main head)

Regression introduced by the response-shaping rework (the same series
that fixed BUG-018). Not present on `3a06321e` (2026-07-02), where the
adapter's grouped-calculation spec passed.

## Summary

For a `GROUP BY` query, NodeDB's result shape diverges from the SELECT
list in three ways:

1. A plain-column select item's `AS` alias is ignored — the result
   column carries the base column name instead of the requested alias.
   Aggregate aliases are honoured.
2. Result columns come back group-keys-first regardless of SELECT-list
   order.
3. An *unaliased* aggregate (`SELECT label, SUM(score) ... GROUP BY
   label`) returns empty cells for the aggregate column.

Non-grouped queries honour aliases and column order correctly.

## Reproduction (psql, port 6432)

```sql
CREATE COLLECTION grp (id TEXT PRIMARY KEY, label TEXT, score FLOAT)
  WITH (engine='document_strict');
INSERT INTO grp (id, label, score) VALUES ('r1','alpha',7);
INSERT INTO grp (id, label, score) VALUES ('r2','beta',3);

-- 1+2: group-key alias dropped, columns reordered group-key-first
SELECT SUM(score) AS sum_score, label AS lbl FROM grp GROUP BY label;
--  label | sum_score          <- expected: sum_score | lbl
--  beta  | 3.0
--  alpha | 7.0

-- 3: unaliased aggregate loses its values entirely
SELECT label, SUM(score) FROM grp GROUP BY label;
--  label | sum(score)
--  beta  |                    <- empty cell, expected 3.0
--  alpha |                    <- empty cell, expected 7.0

-- control: no GROUP BY -> aliases respected
SELECT label AS lbl, score AS s FROM grp WHERE id = 'r1';
--  lbl   | s
--  alpha | 7.0
```

## Impact

ActiveRecord grouped calculations (`Model.group(:label).sum(:score)`,
`.group(...).count`, …) alias every group key
(`"label" AS "table_label"`) and read each group key back by that
alias. With the alias dropped, every group key reads as `nil` and the
result collapses to a single `{nil => <last group's value>}` entry —
silently wrong data, no error.

## Adapter workaround (SHIPPED)

`NodedbAdapter#realias_group_by_columns`: after `perform_query` on a
GROUP BY SELECT, bare `"column" AS "alias"` pairs are parsed from the
SELECT list and the returned base column names are renamed back to the
requested aliases (thin result delegator; values untouched). Column
order is left as-is — ActiveRecord reads by name.

The unaliased-aggregate empty-cell case (3) is not worked around:
ActiveRecord always aliases its aggregates, and hand-written SQL can
add an alias.

Remove the workaround when upstream honours aliases in GROUP BY
output.

## Upstream

Not yet reported upstream.

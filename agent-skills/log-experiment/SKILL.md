---
name: log-experiment
description: Record a training run or experiment in the Notion knowledge graph (Experiments database) — hypothesis, config, outcome, tracker link, linked to its Project. Use when the user asks to log an experiment or run, or wants a completed training run recorded.
---

# log-experiment — record a run in the knowledge graph

Target database: **Experiments**, data source `58c1efcf-d2c8-47ba-93c3-55348f6666e3`
(on the "Research Hub" page). Its `Project` relation points at **Projects**
`25fe1b50-7e41-46ae-90a8-686b7f5ab875`.

## Steps

1. **Gather** (infer from the session where possible; ask only for what's missing):
   name, date (today), hypothesis, key config (hyperparameters that mattered),
   outcome (`success` / `failure` / `inconclusive`), tracker link (the local trackio
   run/project), notes.
2. **Find the project row**: search Projects
   (`collection://25fe1b50-7e41-46ae-90a8-686b7f5ab875`) for the current repo's name.
   If missing, create it first — `Name` = repo name, `Profile` from the repo's
   `~/projects/<profile>/` path, `Status` = `active`, `Repo` = its GitHub URL.
3. **Create the row** via `notion-create-pages` with parent
   `{"type":"data_source_id","data_source_id":"58c1efcf-d2c8-47ba-93c3-55348f6666e3"}`.
   Properties: `Name`, `date:Date:start` (ISO date), `Hypothesis`, `Config`, `Outcome`,
   `Tracker link`, `Notes`, and `Project` = JSON array with the project page URL.
4. **Report** the Notion URL and one line on what the record says.

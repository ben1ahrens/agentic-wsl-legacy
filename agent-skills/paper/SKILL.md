---
name: paper
description: Capture a paper into the Notion knowledge graph — fetch it (arXiv ID, URL, PubMed ref, or PDF), summarize, file it into the Papers database, and link related Ideas. Use when the user says "paper <ref>", or asks to capture, file, or save a paper into their knowledge base.
---

# paper — capture into the knowledge graph

The knowledge graph lives on the "Research Hub" Notion page (`39180cb7-4d75-81a5-b703-df5999c4b6a3`).
Target database: **Papers**, data source `6a5a7be1-3c6f-442a-9abf-2f8d9d298aeb`.
Related: **Ideas** `c63a29c1-201e-4bbd-a6f9-083e1a60e1b2`.

## Steps

1. **Resolve the reference.**
   - arXiv ID (e.g. `2406.01234`) → fetch `https://arxiv.org/abs/<id>`
   - PubMed ID/link → use the PubMed MCP (`get_article_metadata`, `get_full_text_article`)
   - URL → fetch it; local PDF → Read it
2. **Extract**: title, authors, canonical source URL. Write a structured **Summary**
   (problem → method → results, 3–5 sentences) and 2–4 **Key claims** (falsifiable,
   worth citing or testing).
3. **Dedup**: `notion-search` with `data_source_url: collection://6a5a7be1-3c6f-442a-9abf-2f8d9d298aeb`
   for the title. If it exists, update that page instead of creating a duplicate.
4. **Create** via `notion-create-pages` with parent
   `{"type":"data_source_id","data_source_id":"6a5a7be1-3c6f-442a-9abf-2f8d9d298aeb"}`.
   Properties: `Title`, `Authors`, `Source`, `Status` = `"to read"`, `Summary`, `Key claims`.
   Page content: fuller notes — abstract, notable sections/figures, why it was captured.
5. **Link**: search Ideas (`collection://c63a29c1-201e-4bbd-a6f9-083e1a60e1b2`) for related
   entries; when clearly related, set the `Ideas` relation (JSON array of page URLs) and say so.
6. **Report**: the Notion URL + a one-line takeaway.

# Parser Corpus Fixtures

This corpus provides deterministic parser inputs for regression and infrastructure tests.

## Purpose

- Validate parser baseline invariants against real-world-like inputs.
- Let developers add coverage by dropping in fixture files.
- Keep fixture runs deterministic, fast, and offline.

## Folder Layout

```text
POScannerAppTests/Fixtures/ParserCorpus/
  README.md
  cases/
    <case_id>/
      input.json
      notes.md        (optional)
      attachments/    (optional)
      source.png      (optional)
      source.pdf      (optional)
```

## `input.json` Schema (v1)

```json
{
  "schemaVersion": 1,
  "caseId": "string",
  "profile": "ecommerceCart|tabularInvoice|generic",
  "vendorHint": "string|null",
  "rawText": "string",
  "rows": [
    { "cells": ["string"], "confidence": 0.0 }
  ],
  "barcodes": ["string"],
  "locale": "en_US",
  "currency": "USD"
}
```

Required:

- `schemaVersion`
- `caseId`
- `profile`
- `rawText`

Optional:

- `vendorHint`, `rows`, `barcodes`, `locale`, `currency`

## How To Add A Case

1. Create a new directory under `cases/`, e.g. `cases/new_case_001/`.
2. Add `input.json` using schema v1.
3. (Optional) Add `notes.md` and supporting attachments.
4. Run test gates. The corpus loader auto-discovers all `input.json` files.

No new test code should be required.

## Data Rules

- Use anonymized content only.
- Do not commit real shop names, customer data, emails, phone numbers, or order IDs.
- Keep fixture text concise to preserve test speed.

## Discovery and Execution

- Tests discover fixtures by scanning `Fixtures/ParserCorpus/cases/**/input.json` in the test bundle resources.
- Cases are validated and sorted by `caseId` for deterministic order.
- Failures include `caseId`, `profile`, and a raw text excerpt.

## Minimal Example

```json
{
  "schemaVersion": 1,
  "caseId": "minimal_generic_001",
  "profile": "generic",
  "vendorHint": "ACME PARTS",
  "rawText": "ACME PARTS\\nInvoice INV-1001\\nPart BP-100 Qty 2 Unit 15.00 Total 30.00",
  "locale": "en_US",
  "currency": "USD"
}
```

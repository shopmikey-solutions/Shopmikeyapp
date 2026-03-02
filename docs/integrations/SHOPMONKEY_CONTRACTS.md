# Shopmonkey Contracts (Tickets / Orders / Inventory)

This document records the Shopmonkey endpoint contract used by the app for ticket/order workflows.

Contract source policy:
- If an official docs URL is available, list it.
- If not available in-repo, mark the endpoint as `capability-proved required` and enforce it with endpoint contract tests.

## Base URL

- Sandbox base URL: `https://sandbox-api.shopmonkey.cloud/v3`

## Endpoint Registry

| Purpose | Method | Path | Contract source |
|---|---|---|---|
| Fetch open tickets | `GET` | `/order` | capability-proved required |
| Fetch ticket detail | `GET` | `/order/{id}` | capability-proved required |
| Fetch services for order/ticket | `GET` | `/order/{orderId}/service` | capability-proved required |
| Add part to selected service (ticket mutation) | `POST` | `/order/{orderId}/service/{serviceId}/part` | Official docs: [Shopmonkey Part resource](https://shopmonkey.dev/resources/part) (`Add Part to Service`) |
| Legacy direct ticket line add (deprecated fallback candidate; not used by mutation flow) | `POST` | `/order/{ticketId}/part` | capability-proved required |
| Fetch inventory parts | `POST` | `/inventory_part/search` | capability-proved required |

## Deterministic Rules

1. No endpoint guessing in mutation flows.
2. Ticket mutation requires known `orderId` and `serviceId`.
3. If service context is unknown:
   - fetch services and auto-select only when exactly one service exists
   - otherwise require explicit user selection
   - if offline and no cached service selection, block mutation and show deterministic guidance
4. Endpoint changes must update:
   - this document
   - endpoint contract tests (`POScannerAppTests/ShopmonkeyContractEndpointTests.swift`)

## Capability Proof Mechanism

- `ShopmonkeyAPI.runEndpointProbe()` is available for controlled capability checks.
- CI contract tests assert request method/path and fail fast on path drift.

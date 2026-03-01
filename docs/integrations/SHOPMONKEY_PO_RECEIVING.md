# Shopmonkey PO Receiving Contract (Audit: PR-F5a)

This document captures the receiving contract assumptions codified in `ShopmonkeyAPI.receivePurchaseOrderLineItem(...)`.

## Endpoint candidates (in fallback order)

1. `POST /purchase_order/{purchaseOrderId}/line_item/{lineItemId}/receive`
2. `POST /purchase_order/{purchaseOrderId}/part/{lineItemId}/receive`
3. `POST /purchase_order/{purchaseOrderId}/receive`
4. `POST /purchase_order/{purchaseOrderId}/receiving`

Fallback rules:
- `404` / `405`: route unavailable, try next.
- `400` / `422`: payload shape mismatch, try next.

## Request payload contract

Line-level payload encodes compatibility aliases for both id and quantity keys:
- id keys: `line_item_id`, `lineItemId`, `id`
- quantity keys (when provided): `quantity_received`, `quantityReceived`, `received_quantity`, `receivedQuantity`, `quantity`, `qty`

PO-level payload wraps line-level payloads under:
- `line_items`, `lineItems`, `items`, `received_items`, `receivedItems`

## Response mapping

The receive API decodes PO detail from response envelopes when available:
- direct object
- `data`
- `result`
- `purchase_order` / `purchaseOrder`
- `response` / `order`

If the receive response does not contain a decodable PO object, the client falls back to `GET /purchase_order/{id}`.

## Receiving state fields

`quantityReceived` on `PurchaseOrderLineItem` is mapped from line item fields when present:
- `quantity_received`
- `quantityReceived`
- `received_quantity`
- `receivedQuantity`
- `received_qty`
- `receivedQty`
- `qty_received`
- `qtyReceived`

This field can be supplied by:
- `GET /purchase_order/{id}` response, and/or
- receive endpoint response payloads.

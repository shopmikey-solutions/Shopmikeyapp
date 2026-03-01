//
//  ParserNoiseTaxonomy.swift
//  POScannerApp
//

import Foundation

public enum ParserNoiseTaxonomy {
    // Ecommerce status rows that should never become product line items.
    public static let ecommerceStatusPrefixKeywords: [String] = [
        "fits ",
        "warning:",
        "reg.",
        "discount:",
        "in stock",
        "purchase of"
    ]

    public static let ecommerceStatusContainsKeywords: [String] = [
        "free pick up",
        "pick up today",
        "deliver by",
        "available within",
        "call store to order",
        "check other stores",
        "same day eligible",
        "same dayeligible",
        "deal applied",
        "report a problem",
        "arrange a return"
    ]

    // Checkout/cart-summary rail content that should never be treated as item detail.
    public static let ecommerceCheckoutRailContainsKeywords: [String] = [
        "cart summary",
        "item subtotal",
        "total discounts",
        "applied deal",
        "apply promo code",
        "o'rewards reward",
        "core charges",
        "est. total",
        "continue to checkout",
        "pay with",
        "available payment methods",
        "pickup at",
        "have questions or need help",
        "shipping estimates",
        "privacy policy",
        "calculated at checkout",
        "code apply"
    ]

    // Legal/compliance footer lines that should be filtered from item parsing.
    public static let legalComplianceContainsKeywords: [String] = [
        "p65warnings",
        "reproductive harm",
        "chemicals known to the state of california",
        "all the parts your car will ever need"
    ]

    public static let legalComplianceInfoPairKeywords: (trigger: String, secondary: [String]) = (
        "for more information",
        ["go to", "visit"]
    )

    public static let legalComplianceOrderStatusPairKeywords: [String] = [
        "http://",
        "https://"
    ]

    public static let legalComplianceOrderStatusSecondaryKeyword = "orderstatus"

    public static let parserSummaryUpperKeywords: [String] = [
        "SUBTOTAL",
        "TOTAL",
        "TAX",
        "BALANCE"
    ]

    // Keep this aligned with InvoiceLineClassifier.isLaborServiceLine fee exceptions.
    public static let laborFeeSignalKeywords: [String] = [
        "fee",
        "shop-fee",
        "shop fee",
        "env-fee",
        "env fee",
        "disposal",
        "disposal fee",
        "hazmat",
        "environmental",
        "environmental charge",
        "shop supplies",
        "shipping",
        "freight",
        "core",
        "core charge",
        "surcharge",
        "mount",
        "balance"
    ]

    public static let handoffLowSignalKeywords: Set<String> = [
        "remittance",
        "wire transfer",
        "terms and conditions",
        "thank you for your business",
        "payment instructions",
        "ach preferred",
        "free pick up",
        "pick up today",
        "available within",
        "call store to order",
        "check other stores",
        "same day eligible",
        "deal applied",
        "purchase of",
        "warning:",
        "p65warnings",
        "reproductive harm"
    ]
}

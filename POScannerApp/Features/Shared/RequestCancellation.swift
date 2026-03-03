//
//  RequestCancellation.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreNetworking

func isRequestCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }

    if let urlError = error as? URLError {
        return urlError.code == .cancelled
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
        return true
    }

    if let apiError = error as? APIError,
       case .network(let nestedError) = apiError {
        return isRequestCancellation(nestedError)
    }

    return false
}

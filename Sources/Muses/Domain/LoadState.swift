import Foundation

/// A load result never collapses failure into empty content. Stale data can
/// remain visible while its refresh error is presented alongside it.
enum LoadState<Value> {
    case idle
    case loading(previous: Value?)
    case content(Value)
    case empty
    case failure(message: String, staleValue: Value?)

    var value: Value? {
        switch self {
        case .loading(let previous): previous
        case .content(let value): value
        case .failure(_, let staleValue): staleValue
        case .idle, .empty: nil
        }
    }

    var errorMessage: String? {
        guard case .failure(let message, _) = self else { return nil }
        return message
    }

    var isLoading: Bool {
        guard case .loading = self else { return false }
        return true
    }

    var isStale: Bool {
        guard case .failure(_, let staleValue) = self else { return false }
        return staleValue != nil
    }
}

extension LoadState: Equatable where Value: Equatable {}
extension LoadState: Sendable where Value: Sendable {}

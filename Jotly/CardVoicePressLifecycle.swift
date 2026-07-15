import Foundation

struct CardVoicePressLifecycle {
    enum Event: Equatable {
        case began(isInside: Bool)
        case moved(isInside: Bool)
        case ended(isInside: Bool)
        case cancelled
    }

    enum Action: Equatable {
        case start
        case setCancelState(Bool)
        case finish(shouldCancel: Bool)
        case cancel
    }

    private(set) var isActive = false

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .began(let isInside):
            guard !isActive else { return [] }
            isActive = true
            return [.start, .setCancelState(!isInside)]

        case .moved(let isInside):
            guard isActive else { return [] }
            return [.setCancelState(!isInside)]

        case .ended(let isInside):
            guard isActive else { return [] }
            isActive = false
            return [
                .setCancelState(!isInside),
                .finish(shouldCancel: !isInside)
            ]

        case .cancelled:
            guard isActive else { return [] }
            isActive = false
            return [.cancel]
        }
    }
}

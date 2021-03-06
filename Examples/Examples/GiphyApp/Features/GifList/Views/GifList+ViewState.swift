//
//  GifList+ViewState.swift
//  Examples
//
//  Created by Thibault Wittemberg on 2021-01-16.
//

import Feedbacks

extension GifList {
    enum ViewState {}
}

extension GifList.ViewState {
    enum Value: ViewState {
        case displayLoading
        case displayLoaded(items: [GifList.ViewState.Item], hasPrevious: Bool, hasNext: Bool, counter: String)
        case displayError

        static let undefined: GifList.ViewState.Value = .displayLoading
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let isFavorite: Bool
    }

    static func stateToViewState(state: State) -> GifList.ViewState.Value {
        switch state {
        case is GifList.States.Loading: return GifList.ViewState.Value.displayLoading
        case let loaded as GifList.States.Loaded: return GifList.ViewState.Value.displayLoaded(items: loaded.gifs.map { Item(id: $0.id,
                                                                                                                             title: $0.title,
                                                                                                                             isFavorite: $1) },
                                                                                               hasPrevious: loaded.currentPage > 0,
                                                                                               hasNext: loaded.currentPage < loaded.totalPage,
                                                                                               counter: "\(loaded.currentPage + 1) / \(loaded.totalPage)")
        case is GifList.States.Failed: return GifList.ViewState.Value.displayError
        default: return .undefined
        }
    }
}

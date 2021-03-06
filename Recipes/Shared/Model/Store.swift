//
//  Store.swift
//  Recipes
//
//  Created by Majid Jabrayilov on 11/10/19.
//  Copyright © 2019 Majid Jabrayilov. All rights reserved.
//
import Foundation
import Combine

struct Reducer<State, Action, Environment> {
    let reduce: (inout State, Action, Environment) -> AnyPublisher<Action, Never>

    func callAsFunction(
        _ state: inout State,
        _ action: Action,
        _ environment: Environment
    ) -> AnyPublisher<Action, Never> {
        reduce(&state, action, environment)
    }

    func indexed<LiftedState, LiftedAction, LiftedEnvironment, Key>(
        keyPath: WritableKeyPath<LiftedState, [Key: State]>,
        extractAction: @escaping (LiftedAction) -> (Key, Action)?,
        embedAction: @escaping (Key, Action) -> LiftedAction,
        extractEnvironment: @escaping (LiftedEnvironment) -> Environment
    ) -> Reducer<LiftedState, LiftedAction, LiftedEnvironment> {
        .init { state, action, environment in
            guard let (index, action) = extractAction(action) else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            let environment = extractEnvironment(environment)
            return self.optional()
                .reduce(&state[keyPath: keyPath][index], action, environment)
                .map { embedAction(index, $0) }
                .eraseToAnyPublisher()
        }
    }

    func indexed<LiftedState, LiftedAction, LiftedEnvironment>(
        keyPath: WritableKeyPath<LiftedState, [State]>,
        extractAction: @escaping (LiftedAction) -> (Int, Action)?,
        embedAction: @escaping (Int, Action) -> LiftedAction,
        extractEnvironment: @escaping (LiftedEnvironment) -> Environment
    ) -> Reducer<LiftedState, LiftedAction, LiftedEnvironment> {
        .init { state, action, environment in
            guard let (index, action) = extractAction(action) else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            let environment = extractEnvironment(environment)
            return self.reduce(&state[keyPath: keyPath][index], action, environment)
                .map { embedAction(index, $0) }
                .eraseToAnyPublisher()
        }
    }

    func optional() -> Reducer<State?, Action, Environment> {
        .init { state, action, environment in
            if state != nil {
                return self(&state!, action, environment)
            } else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
        }
    }

    func lift<LiftedState, LiftedAction, LiftedEnvironment>(
        keyPath: WritableKeyPath<LiftedState, State>,
        extractAction: @escaping (LiftedAction) -> Action?,
        embedAction: @escaping (Action) -> LiftedAction,
        extractEnvironment: @escaping (LiftedEnvironment) -> Environment
    ) -> Reducer<LiftedState, LiftedAction, LiftedEnvironment> {
        .init { state, action, environment in
            let environment = extractEnvironment(environment)
            guard let action = extractAction(action) else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            let effect = self(&state[keyPath: keyPath], action, environment)
            return effect.map(embedAction).eraseToAnyPublisher()
        }
    }

    static func combine(_ reducers: Reducer...) -> Reducer {
        .init { state, action, environment in
            let effects = reducers.compactMap { $0(&state, action, environment) }
            return Publishers.MergeMany(effects).eraseToAnyPublisher()
        }
    }
}

import os.log

extension Reducer {
    func signpost(log: OSLog = OSLog(subsystem: "com.aaplab.food", category: "Reducer")) -> Reducer {
        .init { state, action, environment in
            os_signpost(.begin, log: log, name: "Action", "%s", String(reflecting: action))
            let effect = self.reduce(&state, action, environment)
            os_signpost(.end, log: log, name: "Action", "%s", String(reflecting: action))
            return effect
        }
    }

    func log(log: OSLog = OSLog(subsystem: "com.aaplab.food", category: "Reducer")) -> Reducer {
        .init { state, action, environment in
            os_log(.default, log: log, "Action %s", String(reflecting: action))
            let effect = self.reduce(&state, action, environment)
            os_log(.default, log: log, "State %s", String(reflecting: state))
            return effect
        }
    }
}

final class Store<State, Action>: ObservableObject {
    @Published private(set) var state: State

    private let reduce: (inout State, Action) -> AnyPublisher<Action, Never>
    private var effectCancellables: [UUID: AnyCancellable] = [:]

    init<Environment>(
        initialState: State,
        reducer: Reducer<State, Action, Environment>,
        environment: Environment
    ) {
        self.state = initialState
        self.reduce = { state, action in
            reducer(&state, action, environment)
        }
    }

    func send(_ action: Action) {
        let effect = reduce(&state, action)

        var didComplete = false
        let uuid = UUID()

        let cancellable = effect
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] _ in
                    didComplete = true
                    self?.effectCancellables[uuid] = nil
                },
                receiveValue: { [weak self] in self?.send($0) }
            )

        if !didComplete {
            effectCancellables[uuid] = cancellable
        }
    }

    func transformed<TransformedState: Equatable, TransformedAction>(
        transformState: @escaping (State) -> TransformedState,
        transformAction: @escaping (TransformedAction) -> Action
    ) -> Store<TransformedState, TransformedAction> {
        let store = Store<TransformedState, TransformedAction>(
            initialState: transformState(state),
            reducer: Reducer { _, action, _ in
                self.send(transformAction(action))
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            },
            environment: ()
        )

        $state
            .map(transformState)
            .removeDuplicates()
            .assign(to: &store.$state)

        return store
    }
}

import SwiftUI

extension Store {
    func binding<Value>(
        for keyPath: KeyPath<State, Value>,
        toAction: @escaping (Value) -> Action
    ) -> Binding<Value> {
        Binding<Value>(
            get: { self.state[keyPath: keyPath] },
            set: { self.send(toAction($0)) }
        )
    }
}

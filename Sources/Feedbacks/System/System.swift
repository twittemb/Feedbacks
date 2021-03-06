//
//  System.swift
//  
//
//  Created by Thibault Wittemberg on 2020-12-25.
//

import Combine
import CombineExt
import Dispatch
import Foundation

/// A System is a software component that is able to self-regulate by using the resulting value from its
/// computations as the next input to itself, constantly adjusting this value according to given rules.
/// In order to address the Open/Closed principle, a System is composed of Feedbacks. Feedbacks
/// can be added when new features are to be handled by the System. Feedbacks aim to induce a State
/// mutation based on a previous value of the State, eventually executing some side effects.
public class System {
    public let initialState: InitialState
    public internal(set) var feedbacks: Feedbacks
    public private(set) var transitions: Transitions

    private var subscriptions = [AnyCancellable]()

    /// Builds a System based on its three components: an initial state, some feedbacks, a state machine
    /// By default, the System will be executed an a serial background queue. This can be altered thanks to the `.execute(on:)` modifier.
    /// - Parameter components: the three components of the System
    public convenience init(@SystemBuilder _ components: () -> (InitialState, Feedbacks, Transitions)) {
        let (initialState, feedbacks, transitions) = System.decode(builder: components)
        self.init(initialState: initialState,
                  feedbacks: feedbacks,
                  transitions: transitions)
    }

    init(initialState: InitialState,
         feedbacks: Feedbacks,
         transitions: Transitions) {
        self.initialState = initialState
        self.feedbacks = feedbacks
        self.transitions = transitions
    }

    static func decode(builder system: () -> (InitialState, Feedbacks, Transitions)) -> (InitialState, Feedbacks, Transitions) {
        let (initialState, feedbacks, transitions) = system()
        return (initialState, feedbacks, transitions)
    }
}

public extension System {
    /// The reactive stream that stands for the flow of States produced by the System
    /// Once this stream has been subscribed to, the initial state is given as an input to the feedbacks.
    /// Then the feedbacks can publish event that will trigger some transitions, generating a new state, and so on and so forth.
    var stream: AnyPublisher<State, Never> {
        Deferred<AnyPublisher<State, Never>> { [initialState, feedbacks, transitions] in
            let currentState = ReplaySubject<State, Never>(bufferSize: 1)

            // merging all the effects into one event stream
            let stateInputStream = currentState.eraseToAnyPublisher()
            let eventStream = feedbacks.eventStream(stateInputStream)

            return transitions.scheduledReducer(initialState.value, eventStream)
                .prepend(initialState.value)
                .handleEvents(receiveOutput: currentState.send)
                .eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    /// Subscribes to the state stream and store the cancellable in the System.
    /// The subscription will be canceled once the System is deinit.
    @discardableResult
    func run() -> Self {
        self.stream.sink(receiveValue: { _ in }).store(in: &self.subscriptions)
        return self
    }

    /// Subscribes to the state stream and store the cancellable in the System.
    /// The subscription will be canceled once the System is deinit.
    @discardableResult
    func run<SchedulerType: Scheduler>(subscribeOn scheduler: SchedulerType) -> Self {
        self.stream.subscribe(on: scheduler).sink(receiveValue: { _ in }).store(in: &self.subscriptions)
        return self
    }
}

// MARK: modifiers
public extension System {
    /// Alter the scheduler on which the System runs (by default a serial background queue). If no schedulers are
    /// set for the feedbacks, then all components of the System will be executed on the System's scheduler.
    /// If some schedulers are set for the feedbacks, then only the transitions will occur on the System's scheduler.
    /// - Parameter scheduler: the scheduler on which to execute the System
    /// - Returns: The newly scheduled System
    func execute<SchedulerType: Scheduler>(on scheduler: SchedulerType) -> Self {
        self.feedbacks = self.feedbacks.execute(on: scheduler)
        self.transitions = self.transitions.execute(on: scheduler)
        return self
    }

    /// Attach the System to a mediator, so that every expected mediator value will trigger a System event
    ///
    /// `mySystem.attach(to: sharedMediator, emitSystemEvent: { $0 == 1 ? MyEvent() : nil })`
    ///
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - emitSystemEvent: a factory closure to select the mediator value and the event to trigger. You should return nil if no event is to be triggered
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator>(
        to mediator: MediatorType,
        emitSystemEvent: @escaping (MediatorType.Output) -> Event?
    ) -> System where MediatorType.Failure == Never {
        self.feedbacks = self.feedbacks.attach(to: mediator, emitSystemEvent: emitSystemEvent)
        return self
    }

    /// Attach the System to a mediator, so that every expected mediator value will trigger a System event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onMediatorValue: the mediator value that should trigger a System event
    ///   - emitSystemEvent: the System event to emit when the mediator value is reached
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator>(
        to mediator: MediatorType,
        onMediatorValue: MediatorType.Output,
        emitSystemEvent: @escaping (MediatorType.Output) -> Event
    ) -> System where MediatorType.Failure == Never, MediatorType.Output: Equatable {
        self.feedbacks = self.feedbacks.attach(to: mediator, onMediatorValue: onMediatorValue, emitSystemEvent: emitSystemEvent)
        return self
    }

    /// Attach the System to a mediator, so that every expected mediator value will trigger a System event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onMediatorValue: the mediator value that should trigger a System event
    ///   - emitSystemEvent: the System event to emit when the mediator value is reached
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator>(
        to mediator: MediatorType,
        onMediatorValue: MediatorType.Output,
        emitSystemEvent: Event
    ) -> System where MediatorType.Failure == Never, MediatorType.Output: Equatable {
        self.feedbacks = self.feedbacks.attach(to: mediator, onMediatorValue: onMediatorValue, emitSystemEvent: emitSystemEvent)
        return self
    }

    /// Attach the System to a mediator, so that every expected System state value  will trigger a mediator event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - emitMediatorValue: a factory closure to select the state value and the mediator value to trigger. You should return nil if no event is to be triggered
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator>(
        to mediator: MediatorType,
        emitMediatorValue: @escaping (State) -> MediatorType.Output?
    ) -> System where MediatorType.Failure == Never {
        self.feedbacks = self.feedbacks.attach(to: mediator, emitMediatorValue: emitMediatorValue)
        return self
    }

    /// Attach the System to a mediator, so that every expected System state value  will trigger a mediator event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onSystemStateType: the State type that should trigger a mediator event
    ///   - emitMediatorValue: the mediator value to emit
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator, StateType: State>(
        to mediator: MediatorType,
        onSystemStateType: StateType.Type,
        emitMediatorValue: @escaping (StateType) -> MediatorType.Output
    ) -> System where MediatorType.Failure == Never {
        self.feedbacks = self.feedbacks.attach(to: mediator, onSystemStateType: onSystemStateType, emitMediatorValue: emitMediatorValue)
        return self
    }

    /// Attach the System to a mediator, so that every expected System state value  will trigger a mediator event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onSystemStateType: the State type that should trigger a mediator event
    ///   - emitMediatorValue: the mediator value to emit
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator, StateType: State>(
        to mediator: MediatorType,
        onSystemStateType: StateType.Type,
        emitMediatorValue: MediatorType.Output
    ) -> System where MediatorType.Failure == Never {
        self.feedbacks = self.feedbacks.attach(to: mediator, onSystemStateType: onSystemStateType, emitMediatorValue: emitMediatorValue)
        return self
    }

    /// Attach the System to a mediator, so that every expected System state value  will trigger a mediator event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onSystemState: the State value that should trigger a mediator event
    ///   - emitMediatorValue: the mediator value to emit
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator, StateType: State>(
        to mediator: MediatorType,
        onSystemState: StateType,
        emitMediatorValue: @escaping (StateType) -> MediatorType.Output
    ) -> System where MediatorType.Failure == Never, StateType: Equatable {
        self.feedbacks = self.feedbacks.attach(to: mediator, onSystemState: onSystemState, emitMediatorValue: emitMediatorValue)
        return self
    }

    /// Attach the System to a mediator, so that every expected System state value  will trigger a mediator event
    /// - Parameters:
    ///   - mediator: the mediator attached to the System
    ///   - onSystemState: the State value that should trigger a mediator event
    ///   - emitMediatorValue: the mediator value to emit
    /// - Returns: the System attached to the mediator
    func attach<MediatorType: Mediator, StateType: State>(
        to mediator: MediatorType,
        onSystemState: StateType,
        emitMediatorValue: MediatorType.Output
    ) -> System where MediatorType.Failure == Never, StateType: Equatable {
        self.feedbacks = self.feedbacks.attach(to: mediator, onSystemState: onSystemState, emitMediatorValue: emitMediatorValue)
        return self
    }

    /// Attach 2 Systems together. When the State type is reached, then the expected event is triggered in the attached System
    /// - Parameters:
    ///   - attachedSystem: the System to attach
    ///   - onSystemStateType: the State type that should trigger the attached System event
    ///   - emitAttachedSystemEvent: the attached System event to emit when the State type is the expected one
    /// - Returns: the  system attached to another one
    @discardableResult
    func attach<SystemStateType: State, AttachedSystemEventType: Event>(
        to attachedSystem: System,
        onSystemStateType: SystemStateType.Type,
        emitAttachedSystemEvent: @escaping (SystemStateType) -> AttachedSystemEventType) -> System {
        let mediator = PassthroughMediator<SystemStateType>()

        _ = self.attach(to: mediator, onSystemStateType: onSystemStateType, emitMediatorValue: { state in
            return state
        })

        _ = attachedSystem.attach(to: mediator) { value -> Event? in
            return emitAttachedSystemEvent(value)
        }

        return self
    }
}

@_functionBuilder
public struct SystemBuilder {
    public static func buildBlock(
        _ initialState: InitialState,
        _ feedbacks: Feedbacks,
        _ transitions: Transitions
    ) -> (InitialState, Feedbacks, Transitions) {
        (initialState, feedbacks, transitions)
    }

    public static func buildBlock(
        _ initialState: InitialState,
        _ feedbacks: Feedbacks,
        _ transitions: Transitions
    ) -> System {
        System {
            initialState
            feedbacks
            transitions
        }
    }

    @available(*, unavailable, message: "You cannot create a System without an initial state")
    public static func buildBlock(
        _ feedbacks: Feedbacks,
        _ transitions: Transitions
    ) -> (InitialState, Feedbacks, Transitions) {
        fatalError()
    }

    @available(*, unavailable, message: "You cannot create a System without an initial state")
    public static func buildBlock(
        _ feedbacks: Feedbacks,
        _ transitions: Transitions
    ) -> System {
        fatalError()
    }
}

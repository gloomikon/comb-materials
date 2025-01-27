import Foundation
import Combine

fileprivate final class ShareReplaySubscription<Output, Failure: Error>: Subscription {

    let capacity: Int
    var subscriber: AnySubscriber<Output,Failure>? = nil
    var demand: Subscribers.Demand = .none
    var buffer: [Output]
    var completion: Subscribers.Completion<Failure>? = nil

    init<S>(
        subscriber: S,
        replay: [Output],
        capacity: Int,
        completion: Subscribers.Completion<Failure>?
    ) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        self.subscriber = AnySubscriber(subscriber)
        self.buffer = replay
        self.capacity = capacity
        self.completion = completion
    }

    func request(_ demand: Subscribers.Demand) {
        if demand != .none {
            self.demand += demand
        }
    }

    func cancel() {
        complete(with: .finished)
    }

    private func complete(with completion: Subscribers.Completion<Failure>) {
        guard let subscriber = subscriber else { return }
        self.subscriber = nil
        self.completion = nil
        self.buffer.removeAll()
        subscriber.receive(completion: completion)
    }

    private func emitAsNeeded() {
        guard let subscriber = subscriber else { return }
        while demand > .none && !buffer.isEmpty {
            self.demand -= .max(1)
            let nextDemand = subscriber.receive(buffer.removeFirst())
            if nextDemand != .none {
                demand += nextDemand
            }
        }
        if let completion = completion {
            complete(with: completion)
        }
    }

    func receive(_ input: Output) {
        guard subscriber != nil else { return }
        buffer.append(input)
        if buffer.count > capacity {
            buffer.removeFirst()
        }
        emitAsNeeded()
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        guard let subscriber = subscriber else { return }
        self.subscriber = nil
        self.buffer.removeAll()
        subscriber.receive(completion: completion)
    }
}

extension Publishers {

    final class ShareReplay<Upstream: Publisher>: Publisher {
        typealias Output = Upstream.Output
        typealias Failure = Upstream.Failure

        private let upstream: Upstream
        private let capacity: Int

        private let lock = NSRecursiveLock()
        private var replay = [Output]()
        private var subscriptions = [ShareReplaySubscription<Output, Failure>]()
        private var completion: Subscribers.Completion<Failure>? = nil

        init(upstream: Upstream, capacity: Int) {
            self.upstream = upstream
            self.capacity = capacity
        }

        func receive<S: Subscriber>(subscriber: S) where Failure == S.Failure, Output == S.Input {
            lock.lock()
            defer { lock.unlock() }

            let subscription = ShareReplaySubscription(
                subscriber: subscriber,
                replay: replay,
                capacity: capacity,
                completion: completion
            )

            subscriptions.append(subscription)
            subscriber.receive(subscription: subscription)

            guard subscriptions.count == 1 else { return }

            let sink = AnySubscriber(
                receiveSubscription: { subscription in
                    subscription.request(.unlimited)
                },
                receiveValue: { [weak self] (value: Output) -> Subscribers.Demand in
                    self?.relay(value)
                    return .none
                },
                receiveCompletion: { [weak self] in
                    self?.complete($0)
                }
            )

            upstream.subscribe(sink)
        }


        private func relay(_ value: Output) {
            lock.lock()
            defer { lock.unlock() }

            guard completion == nil else { return }

            replay.append(value)
            if replay.count > capacity {
                replay.removeFirst()
            }

            subscriptions.forEach {
                $0.receive(value)
            }
        }

        private func complete(_ completion: Subscribers.Completion<Failure>) {
            lock.lock()
            defer { lock.unlock() }
            self.completion = completion
            subscriptions.forEach {
                $0.receive(completion: completion)
            }
        }
    }
}

extension Publisher {
    func shareReplay(capacity: Int = .max) -> Publishers.ShareReplay<Self> {
        Publishers.ShareReplay(upstream: self, capacity: capacity)
    }
}

//: [Next](@next)
/*:
 Copyright (c) 2021 Razeware LLC

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
 distribute, sublicense, create a derivative work, and/or sell copies of the
 Software in any work that is designed, intended, or marketed for pedagogical or
 instructional purposes related to programming, coding, application development,
 or information technology.  Permission for such use, copying, modification,
 merger, publication, distribution, sublicensing, creation of derivative works,
 or sale is expressly withheld.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 */

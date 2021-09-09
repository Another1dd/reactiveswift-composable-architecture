import ComposableArchitecture
import Foundation
import ReactiveSwift
import XCTestDynamicOverlay

struct FactClient {
  var fetch: (Int) -> Effect<String, Error>

  struct Error: Swift.Error, Equatable {}
}

  // This is the "live" fact dependency that reaches into the outside world to fetch trivia.
  // Typically this live implementation of the dependency would live in its own module so that the
  // main feature doesn't need to compile it.
extension FactClient {
  #if compiler(>=5.5)
  static let live = Self(
    fetch: { number in
        Effect.task {
          do {
            let (data, _) = try await URLSession.shared
              .data(from: URL(string: "http://numbersapi.com/\(number)/trivia")!)
            return String(decoding: data, as: UTF8.self)
          } catch {
            await Task.sleep(NSEC_PER_SEC)
            return "\(number) is a good number Brent"
          }
        }
        .setFailureType(to: Error.self)
        .eraseToEffect()
      }
    )
  #else
    static let live = Self(
      fetch: { number in
        URLSession.shared.reactive.data(
          with: URLRequest(url: URL(string: "http://numbersapi.com/\(number)/trivia")!)
        )
        .map { data, _ in String(decoding: data, as: UTF8.self) }
        .flatMapError { _ in
          Effect(value: "\(number) is a good number Brent")
            .delay(1, on: QueueScheduler.main)
        }
        .promoteError(Error.self)
      })
  #endif
}

#if DEBUG
  extension FactClient {
    // This is the "failing" fact dependency that is useful to plug into tests that you want
    // to prove do not need the dependency.
    static let failing = Self(
      fetch: { _ in
        XCTFail("\(Self.self).fact is unimplemented.")
        return .none
      })
  }
#endif

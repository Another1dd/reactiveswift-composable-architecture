import ComposableArchitecture
import Foundation
import ReactiveSwift
import XCTest
import XCTestDynamicOverlay

@testable import VoiceMemos

@MainActor
class VoiceMemosTests: XCTestCase {
  let mainRunLoop = TestScheduler()

  func testRecordMemoHappyPath() async {
    // NB: Combine's concatenation behavior is different in 13.3
    guard #available(iOS 13.4, *) else { return }

    let didFinish = AsyncThrowingStream<Bool, Error>.streamWithContinuation()

    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioRecorder.currentTime = { 2.5 }
    environment.audioRecorder.requestRecordPermission = { true }
    environment.audioRecorder.startRecording = { _ in
      try await didFinish.stream.first { _ in true }!
    }
    environment.audioRecorder.stopRecording = {
      didFinish.continuation.yield(true)
      didFinish.continuation.finish()
    }
    environment.mainRunLoop = mainRunLoop
    environment.temporaryDirectory = { URL(fileURLWithPath: "/tmp") }
    environment.uuid = { UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")! }

    let store = TestStore(
      initialState: VoiceMemosState(),
      reducer: voiceMemosReducer,
      environment: environment
    )

    let recordButtonTappedTask = await store.send(.recordButtonTapped)
    await self.mainRunLoop.advance()
    await store.receive(.recordPermissionResponse(true)) {
      $0.audioRecorderPermission = .allowed
      $0.currentRecording = VoiceMemosState.CurrentRecording(
        date: Date(timeIntervalSinceReferenceDate: 0),
        mode: .recording,
        url: URL(fileURLWithPath: "/tmp/DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF.m4a")
      )
    }
    await self.mainRunLoop.advance(by: 1)
    await store.receive(.currentRecordingTimerUpdated) {
      $0.currentRecording?.duration = 1
    }
    await self.mainRunLoop.advance(by: 1)
    await store.receive(.currentRecordingTimerUpdated) {
      $0.currentRecording?.duration = 2
    }
    await self.mainRunLoop.advance(by: 0.5)
    await store.send(.recordButtonTapped) {
      $0.currentRecording?.mode = .encoding
    }
    await store.receive(.finalRecordingTime(2.5)) {
      $0.currentRecording?.duration = 2.5
    }
    await store.receive(.audioRecorderDidFinish(.success(true))) {
      $0.currentRecording = nil
      $0.voiceMemos = [
        VoiceMemo(
          date: Date(timeIntervalSinceReferenceDate: 0),
          duration: 2.5,
          mode: .notPlaying,
          title: "",
          url: URL(fileURLWithPath: "/tmp/DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF.m4a")
        )
      ]
    }
    await recordButtonTappedTask.finish()
  }

  func testPermissionDenied() async {
    let didOpenSettings = ActorIsolated(false)

    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioRecorder.requestRecordPermission = { false }
    environment.mainRunLoop = mainRunLoop
    environment.openSettings = { await didOpenSettings.setValue(true) }

    let store = TestStore(
      initialState: VoiceMemosState(),
      reducer: voiceMemosReducer,
      environment: environment
    )

    await store.send(.recordButtonTapped)
    await store.receive(.recordPermissionResponse(false)) {
      $0.alert = AlertState(title: TextState("Permission is required to record voice memos."))
      $0.audioRecorderPermission = .denied
    }
    await store.send(.alertDismissed) {
      $0.alert = nil
    }
    await store.send(.openSettingsButtonTapped).finish()
    await didOpenSettings.withValue { XCTAssert($0) }
  }

  func testRecordMemoFailure() async {
    struct SomeError: Error, Equatable {}
    let didFinish = AsyncThrowingStream<Bool, Error>.streamWithContinuation()

    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioRecorder.currentTime = { 2.5 }
    environment.audioRecorder.requestRecordPermission = { true }
    environment.audioRecorder.startRecording = { _ in
      try await didFinish.stream.first { _ in true }!
    }
    environment.mainRunLoop = TestScheduler(startDate: Date(timeIntervalSince1970: 0))
    environment.temporaryDirectory = { URL(fileURLWithPath: "/tmp") }
    environment.uuid = { UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")! }

    let store = TestStore(
      initialState: VoiceMemosState(),
      reducer: voiceMemosReducer,
      environment: environment
    )

    await store.send(.recordButtonTapped)
    await self.mainRunLoop.advance(by: 0.5)
    await store.receive(.recordPermissionResponse(true)) {
      $0.audioRecorderPermission = .allowed
      $0.currentRecording = VoiceMemosState.CurrentRecording(
        date: Date(timeIntervalSince1970: 0),
        mode: .recording,
        url: URL(fileURLWithPath: "/tmp/DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF.m4a")
      )
    }

    didFinish.continuation.finish(throwing: SomeError())
    await self.mainRunLoop.advance(by: 0.5)
    await store.receive(.audioRecorderDidFinish(.failure(SomeError()))) {
      $0.alert = AlertState(title: TextState("Voice memo recording failed."))
      $0.currentRecording = nil
    }
  }

  func testPlayMemoHappyPath() async {
    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioPlayer.play = { _ in
      try await self.mainRunLoop.sleep(for: .milliseconds(1250))
      return true
    }
    environment.mainRunLoop = mainRunLoop

    let url = URL(fileURLWithPath: "pointfreeco/functions.m4a")
    let store = TestStore(
      initialState: VoiceMemosState(
        voiceMemos: [
          VoiceMemo(
            date: Date(),
            duration: 1.25,
            mode: .notPlaying,
            title: "",
            url: url
          )
        ]
      ),
      reducer: voiceMemosReducer,
      environment: environment
    )

    let task = await store.send(.voiceMemo(id: url, action: .playButtonTapped)) {
      $0.voiceMemos[id: url]?.mode = .playing(progress: 0)
    }
    await self.mainRunLoop.advance(by: 0.5)
    await store.receive(.voiceMemo(id: url, action: .timerUpdated(0.5))) {
      $0.voiceMemos[id: url]?.mode = .playing(progress: 0.4)
    }
    await self.mainRunLoop.advance(by: 0.5)
    await store.receive(.voiceMemo(id: url, action: .timerUpdated(1))) {
      $0.voiceMemos[id: url]?.mode = .playing(progress: 0.8)
    }
    await self.mainRunLoop.advance(by: 0.25)
    await store.receive(.voiceMemo(id: url, action: .audioPlayerClient(.success(true)))) {
      $0.voiceMemos[id: url]?.mode = .notPlaying
    }
    await task.cancel()
  }

  func testPlayMemoFailure() async {
    struct SomeError: Error, Equatable {}

    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioPlayer.play = { _ in throw SomeError() }
    environment.mainRunLoop = mainRunLoop

    let url = URL(fileURLWithPath: "pointfreeco/functions.m4a")
    let store = TestStore(
      initialState: VoiceMemosState(
        voiceMemos: [
          VoiceMemo(
            date: Date(),
            duration: 30,
            mode: .notPlaying,
            title: "",
            url: url
          )
        ]
      ),
      reducer: voiceMemosReducer,
      environment: environment
    )

    let task = await store.send(.voiceMemo(id: url, action: .playButtonTapped)) {
      $0.voiceMemos[id: url]?.mode = .playing(progress: 0)
    }
    await store.receive(.voiceMemo(id: url, action: .audioPlayerClient(.failure(SomeError())))) {
      $0.alert = AlertState(title: TextState("Voice memo playback failed."))
      $0.voiceMemos[id: url]?.mode = .notPlaying
    }
    await task.cancel()
  }

  func testStopMemo() async {
    let url = URL(fileURLWithPath: "pointfreeco/functions.m4a")
    let store = TestStore(
      initialState: VoiceMemosState(
        voiceMemos: [
          VoiceMemo(
            date: Date(),
            duration: 30,
            mode: .playing(progress: 0.3),
            title: "",
            url: url
          )
        ]
      ),
      reducer: voiceMemosReducer,
      environment: .unimplemented
    )

    await store.send(.voiceMemo(id: url, action: .playButtonTapped)) {
      $0.voiceMemos[id: url]?.mode = .notPlaying
    }
  }

  func testDeleteMemo() async {
    let url = URL(fileURLWithPath: "pointfreeco/functions.m4a")
    let store = TestStore(
      initialState: VoiceMemosState(
        voiceMemos: [
          VoiceMemo(
            date: Date(),
            duration: 30,
            mode: .playing(progress: 0.3),
            title: "",
            url: url
          )
        ]
      ),
      reducer: voiceMemosReducer,
      environment: .unimplemented
    )

    await store.send(.voiceMemo(id: url, action: .delete)) {
      $0.voiceMemos = []
    }
  }

  func testDeleteMemoWhilePlaying() async {
    let url = URL(fileURLWithPath: "pointfreeco/functions.m4a")
    var environment = VoiceMemosEnvironment.unimplemented
    environment.audioPlayer.play = { _ in try await Task.never() }
    environment.mainRunLoop = mainRunLoop

    let store = TestStore(
      initialState: VoiceMemosState(
        voiceMemos: [
          VoiceMemo(
            date: Date(),
            duration: 10,
            mode: .notPlaying,
            title: "",
            url: url
          )
        ]
      ),
      reducer: voiceMemosReducer,
      environment: environment
    )

    await store.send(.voiceMemo(id: url, action: .playButtonTapped)) {
      $0.voiceMemos[id: url]?.mode = .playing(progress: 0)
    }
    await store.send(.voiceMemo(id: url, action: .delete)) {
      $0.voiceMemos = []
    }
  }
}

extension VoiceMemosEnvironment {
  static let unimplemented = Self(
    audioPlayer: .unimplemented,
    audioRecorder: .unimplemented,
    mainRunLoop: UnimplementedScheduler(),
    openSettings: XCTUnimplemented("\(Self.self).openSettings"),
    temporaryDirectory: XCTUnimplemented(
      "\(Self.self).temporaryDirectory",
      placeholder: URL(fileURLWithPath: NSTemporaryDirectory())
    ),
    uuid: XCTUnimplemented("\(Self.self).uuid", placeholder: UUID())
  )
}

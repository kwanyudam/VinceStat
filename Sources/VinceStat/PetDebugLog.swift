import Foundation

/// `VINCESTAT_PET_DEBUG=1` 일 때만 stderr 로 한 줄씩 찍는다.
/// 펫이 안 보일 때 "켜지긴 했는지 / 창이 어느 좌표에 생겼는지"를 확인하는 용도다 —
/// 화면 밖이나 다른 모니터에 생기면 눈으로는 원인을 알 수 없다.
func petDebugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["VINCESTAT_PET_DEBUG"] != nil else { return }
    NSLog("[pet] %@", message)
}

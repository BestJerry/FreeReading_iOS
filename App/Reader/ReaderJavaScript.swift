import Foundation
import WebKit

/// 将 WebKit 回调限定为一次完成并提供超时，页面销毁或进程异常不会无限挂住起播查询。
@MainActor
enum ReaderJavaScript {
    static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let request = Pending(continuation)
            request.timeout = Task {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                request.finish(.failure(NSError(domain: "FreeReading.Reader", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "原文定位超时，请重试。"])))
            }
            webView.evaluateJavaScript(script) { result, error in
                Task { @MainActor in
                    if let error { request.finish(.failure(error)) }
                    else { request.finish(.success(result ?? NSNull())) }
                }
            }
        }
    }

    private final class Pending {
        var continuation: CheckedContinuation<Any, Error>?
        var timeout: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Any, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Any, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(with: result)
        }
    }
}

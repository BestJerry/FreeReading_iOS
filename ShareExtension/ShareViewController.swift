import UIKit
import UniformTypeIdentifiers
import FreeReadingCore

/// 分享扩展仅暂存原文件，避免在扩展内为长书建立索引或绕过系统限制打开主应用。
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let cancellation = CopyCancellation()
    private var providerProgress: Progress?
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "导入 FreeReading"; title.font = .preferredFont(forTextStyle: .title2)
        status.text = "正在复制 EPUB…"; status.numberOfLines = 0
        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.addTarget(self, action: #selector(closeExtension), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, status, spinner, close])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        importAttachment()
    }

    private func importAttachment() {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FreeReadingAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            show("无法访问共享书库。请确认主应用和分享扩展配置了相同的 App Group。"); return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let epubType = "org.idpf.epub-container"
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(epubType) })
                ?? providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            show("未找到 EPUB 文件。也可以在 FreeReading 中从“文件”导入。"); return
        }
        let inbox = ShareInbox(root: container.appendingPathComponent("EPUBInbox", isDirectory: true))
        let token = cancellation
        let declaredEPUB = provider.hasItemConformingToTypeIdentifier(epubType)
        let suggestedName = provider.suggestedName
        let completion: @Sendable (URL?, Error?) -> Void = { [weak self] url, error in
            do {
                guard let url else { throw error ?? ShareInbox.InboxError.invalidFile }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var name = suggestedName ?? url.lastPathComponent
                // 部分提供方的临时 URL 没有扩展名，按其明确声明的 EPUB 类型保留文件名。
                if declaredEPUB, (name as NSString).pathExtension.lowercased() != "epub" { name += ".epub" }
                try inbox.enqueue(from: url, displayName: name, cancelled: { token.isCancelled })
                Task { @MainActor [weak self] in self?.show("已接收 EPUB。请打开 FreeReading，继续导入书架。") }
            } catch is CancellationError { }
            catch { Task { @MainActor [weak self] in self?.show(error.localizedDescription) } }
        }
        if provider.hasItemConformingToTypeIdentifier(epubType) {
            providerProgress = provider.loadFileRepresentation(forTypeIdentifier: epubType, completionHandler: completion)
        } else {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                completion(item as? URL, error)
            }
        }
    }

    private func show(_ message: String) { spinner.stopAnimating(); status.text = message }
    @objc private func closeExtension() {
        cancellation.cancel(); providerProgress?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// 提供方复制回调可在后台线程执行；关闭扩展与复制之间通过锁传递取消状态。
private final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

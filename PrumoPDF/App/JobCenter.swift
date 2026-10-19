import Foundation
import UIKit

/// Controla o OCR em andamento (um arquivo por vez, com fila).
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()

    struct Running: Equatable {
        let itemID: String
        let name: String
        var done: Int = 0
        var total: Int = 0
    }

    @Published private(set) var running: Running?
    @Published private(set) var queue: [String] = []   // ids aguardando

    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func isBusy(with itemID: String) -> Bool {
        running?.itemID == itemID || queue.contains(itemID)
    }

    func startOCR(_ item: PDFItem, library: Library = .shared, flow: AppFlow = .shared) {
        guard !isBusy(with: item.id) else { return }
        if running == nil {
            run(item, library: library, flow: flow)
        } else {
            queue.append(item.id)
            flow.toast("Na fila do OCR: \(item.name)")
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ item: PDFItem, library: Library, flow: AppFlow) {
        running = Running(itemID: item.id, name: item.name)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "OCR") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        let input = item.url
        let output = library.newTempURL()
        let settings = OCRSettings(languages: AppSettings.ocrLanguages)

        let center = self
        task = Task.detached(priority: .userInitiated) {
            var outcome: Result<OCRReport, Error>
            do {
                let report = try await OCRService().run(input: input, output: output, settings: settings) { done, total in
                    Task { @MainActor in
                        center.running?.done = done
                        center.running?.total = total
                    }
                }
                outcome = .success(report)
            } catch {
                outcome = .failure(error)
            }
            if Task.isCancelled { outcome = .failure(CancellationError()) }
            await center.finish(item: item, output: output, outcome: outcome, library: library, flow: flow)
        }
    }

    private func finish(item: PDFItem, output: URL, outcome: Result<OCRReport, Error>,
                        library: Library, flow: AppFlow) {
        switch outcome {
        case .success(let report):
            do {
                let result = try library.adopt(fileAt: output, name: "\(item.name) - OCR", folder: item.folder)
                library.updateAfterOCR(original: item, result: result, report: report)
                var message = "OCR concluído: \(result.name)"
                if !report.reviewPages.isEmpty {
                    message += ". Revise as páginas \(PageSelection.format(report.reviewPages))"
                }
                if report.hadSignature {
                    message += ". A cópia com OCR não mantém a assinatura digital; o original continua válido"
                }
                flow.toast(message, actionTitle: "Abrir") { flow.open(.document(result.id)) }
            } catch {
                flow.toast("Não foi possível salvar o resultado: \(error.localizedDescription)")
            }
        case .failure(let error):
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError {
                flow.toast("OCR cancelado. Nada foi alterado.")
            } else if error is OCRError {
                library.setPendingOCR(item, false)
                flow.toast(error.localizedDescription)
            } else {
                flow.toast("Erro no OCR de “\(item.name)”: \(error.localizedDescription)")
            }
        }
        running = nil
        task = nil
        if let nextID = queue.first {
            queue.removeFirst()
            if let next = library.item(id: nextID) {
                run(next, library: library, flow: flow)
                return
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

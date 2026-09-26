import Foundation
import RacesKit

@Observable
@MainActor
final class InfoViewModel {
    private(set) var jobs: [ServerJobRun] = []
    private(set) var backtests: [ServerBacktest] = []
    private(set) var loadFailure: APIError?
    private(set) var isLoading = false

    private let link: ServerLink

    init(link: ServerLink) {
        self.link = link
    }

    convenience init(environment: AppEnvironment) {
        self.init(link: environment.link)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let server = try link.require()
            async let status = server.status()
            async let reports = server.backtests()
            let (serverStatus, serverBacktests) = try await (status, reports)
            jobs = serverStatus.jobs
            backtests = serverBacktests
            loadFailure = nil
        } catch {
            loadFailure = .from(error)
        }
    }
}

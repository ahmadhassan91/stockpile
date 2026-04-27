import Combine
import Foundation
import StockpileAppShell
import StockpileCameraCapture
import StockpileCaptureFlow
import StockpileMobileAPI
import StockpileOperatorDashboard
import StockpileProcessingRuntime
import StockpileResultsUI
import StockpileUploadPipeline

private extension StockpileAppLaunchMode {
    var landingSection: StockpileShellSection { .capture }
}

@MainActor
final class StockpileAppSession: ObservableObject {
    private enum CompletedRunsSource {
        case none
        case cache
        case backend
    }

    private static let completedRunsCacheKeyPrefix = "StockpileAppSession.completedRuns"
    private static let completedRunsCacheSchemaVersion = "v3"
    private static let pendingRunRecoveryKeyPrefix = "StockpileAppSession.pendingRunRecovery"
    private static let pendingRunRecoverySchemaVersion = "v2"
    private static let maxCachedCompletedRuns = 6
    private static let minimumForegroundRefreshInterval: TimeInterval = 15

    let configuration: StockpileAppConfiguration
    let launchMode: StockpileAppLaunchMode
    let apiService: any StockpileMobileAPIServicing
    let captureFeatureStore: CaptureFeatureStore
    @Published var reviewQueueModel: StockpileResultScreenModel
    @Published var shellStore: StockpileShellStore
    @Published var isReady: Bool
    @Published private(set) var backendConnectionState: StockpileBackendConnectionState

    private var cancellables: Set<AnyCancellable> = []
    private var lastBackendRefreshAt: Date?

    init(
        configuration: StockpileAppConfiguration,
        launchMode: StockpileAppLaunchMode,
        apiService: any StockpileMobileAPIServicing,
        captureFeatureStore: CaptureFeatureStore,
        reviewQueueModel: StockpileResultScreenModel,
        shellStore: StockpileShellStore,
        isReady: Bool = false
    ) {
        self.configuration = configuration
        self.launchMode = launchMode
        self.apiService = apiService
        self.captureFeatureStore = captureFeatureStore
        self.reviewQueueModel = reviewQueueModel
        self.shellStore = shellStore
        self.isReady = isReady
        self.backendConnectionState = configuration.hasIncompleteAuthenticationConfiguration
            ? .incompleteAuthConfiguration(configuration: configuration)
            : .checking(configuration: configuration)
        bindCaptureResults()
        applyDashboardSyncLabel(backendConnectionState.syncLabel)
    }

    static func bootstrap(
        configuration: StockpileAppConfiguration = .current(),
        launchMode: StockpileAppLaunchMode? = nil,
        shellStore: StockpileShellStore? = nil
    ) -> StockpileAppSession {
        let resolvedLaunchMode = launchMode ?? configuration.resolvedLaunchMode()
        return makeOperationalSession(
            configuration: configuration,
            launchMode: resolvedLaunchMode,
            shellStore: shellStore
        )
    }

    var showsEnvironmentBanner: Bool {
        configuration.showsEnvironmentBanner
    }

    var environmentLabel: String {
        configuration.environmentBadgeTitle
    }

    var preferredLandingSection: StockpileShellSection {
        shellStore.selectedSection
    }

    var showsReviewFraming: Bool {
        false
    }

    var reviewFramingTitle: String {
        switch reviewQueueModel.outcome {
        case .verified:
            return "\(reviewQueueModel.pileName) is ready to release"
        case .reviewOnly:
            return "\(reviewQueueModel.pileName) needs an operator decision"
        case .blocked:
            return "\(reviewQueueModel.pileName) needs a recapture plan"
        }
    }

    var reviewFramingSummary: String {
        reviewQueueModel.bannerSummary
    }

    var reviewFramingAction: String {
        reviewQueueModel.recommendedAction
    }

    var reviewFramingStatusLabel: String {
        switch reviewQueueModel.outcome {
        case .verified:
            return "Release"
        case .reviewOnly:
            return "Cross-check"
        case .blocked:
            return "Recapture"
        }
    }

    var reviewFramingConfidenceLabel: String {
        "\(reviewQueueModel.confidence.score)/100 \(reviewQueueModel.confidence.label)"
    }

    var reviewFramingRunLabel: String {
        "Run \(reviewQueueModel.runID)"
    }

    var launchSummary: String {
        "\(configuration.environmentSummary) Live camera capture is armed for the alpha flow, so operators can record the walkaround in-app before upload and review."
    }

    var operationalStatusBanner: StockpileOperationalStatusBannerState? {
        guard backendConnectionState.kind == .attentionRequired else {
            return nil
        }

        return backendConnectionState.banner
    }

    func prepareForLaunch() async {
        guard !isReady else { return }

        // This is the handoff point where the real app will:
        // 1. authenticate the operator,
        // 2. fetch facility/material presets,
        // 3. warm the upload/session API,
        // 4. restore any queued capture jobs and refresh cached completed runs.
        hydrateCompletedRunsFromCache()
        await performBackendRefresh(force: true)
        isReady = true
    }

    func refreshForForegroundIfNeeded(force: Bool = false) async {
        guard isReady else { return }

        if force == false,
           let lastBackendRefreshAt,
           Date().timeIntervalSince(lastBackendRefreshAt) < Self.minimumForegroundRefreshInterval {
            return
        }

        await performBackendRefresh(force: force)
    }

    private func bindCaptureResults() {
        captureFeatureStore.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                self.applyShellState(for: phase)
            }
            .store(in: &cancellables)

        captureFeatureStore.$pendingRunRecoveryState
            .removeDuplicates()
            .sink { [weak self] pendingRun in
                guard let self else { return }
                self.persistPendingRunRecoveryIfNeeded(pendingRun)
            }
            .store(in: &cancellables)
    }

    private func applyShellState(for phase: CaptureFeaturePhase) {
        let progressContent = captureFeatureStore.currentProgressContent
        let currentResult = captureFeatureStore.currentResult
        let provisionalResult = currentResult ?? Self.provisionalReviewModel(
            configuration: configuration,
            phase: phase,
            progressContent: progressContent,
            currentResult: currentResult,
            pendingRunRecoveryState: captureFeatureStore.pendingRunRecoveryState
        )
        let reviewModel = Self.reviewModel(
            configuration: configuration,
            phase: phase,
            progressContent: progressContent,
            currentResult: currentResult,
            provisionalResult: provisionalResult,
            existingReviewModel: reviewQueueModel
        )
        let dashboardResultModel = Self.reviewModel(
            configuration: configuration,
            phase: phase,
            progressContent: progressContent,
            currentResult: currentResult,
            provisionalResult: provisionalResult,
            existingReviewModel: reviewQueueModel
        )
        reviewQueueModel = reviewModel
        shellStore = Self.updating(
            shellStore,
            configuration: configuration,
            phase: phase,
            progressContent: progressContent,
            resultModel: dashboardResultModel,
            currentResult: currentResult
        )
        persistCompletedRunIfNeeded(currentResult)
    }

    private func hydrateCompletedRunsFromCache() {
        let cachedResults = Self.loadCachedCompletedRuns(for: configuration)
        guard cachedResults.isEmpty == false else {
            return
        }
        applyCompletedRuns(cachedResults, source: .cache)
    }

    private func performBackendRefresh(force: Bool) async {
        if lastBackendRefreshAt == nil,
           configuration.hasIncompleteAuthenticationConfiguration == false {
            applyBackendConnectionState(.checking(configuration: configuration))
        }

        let outcome = await refreshRecentRunsFromBackend(force: force)

        switch outcome {
        case let .success(recentRuns):
            applyBackendConnectionState(.connected(configuration: configuration))
            restorePendingRunRecoveryIfNeeded(knownCompletedRuns: recentRuns)
        case let .failure(error):
            applyBackendConnectionState(
                .failed(
                    configuration: configuration,
                    error: error
                )
            )
            restorePendingRunRecoveryIfNeeded(knownCompletedRuns: [])
        }
    }

    private func refreshRecentRunsFromBackend(
        force: Bool = false
    ) async -> Result<[StockpileResultScreenModel], Error> {
        let recentPayloads: [StockpileResultPayload]
        do {
            recentPayloads = try await apiService.fetchRecentResults(
                limit: Self.maxCachedCompletedRuns,
                siteID: configuration.capture.siteID,
                sessionID: nil
            )
        } catch {
            return .failure(error)
        }

        let normalizedResults = Self.normalizedCompletedRuns(
            recentPayloads.map(Self.makeResultModel(from:))
        )
        Self.storeCachedCompletedRuns(normalizedResults, for: configuration)
        applyCompletedRuns(normalizedResults, source: .backend)
        lastBackendRefreshAt = Date()
        return .success(normalizedResults)
    }

    private func applyBackendConnectionState(_ state: StockpileBackendConnectionState) {
        backendConnectionState = state
        applyDashboardSyncLabel(state.syncLabel)
    }

    private func applyDashboardSyncLabel(_ label: String) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false,
              shellStore.dashboardContent.summary.lastSyncLabel != trimmedLabel else {
            return
        }

        let summary = shellStore.dashboardContent.summary
        let updatedSummary = OperatorFacilitySummary(
            facilityName: summary.facilityName,
            operatorLabel: summary.operatorLabel,
            activeSites: summary.activeSites,
            activeJobs: summary.activeJobs,
            reviewQueue: summary.reviewQueue,
            blockedRuns: summary.blockedRuns,
            verifiedToday: summary.verifiedToday,
            lastSyncLabel: trimmedLabel
        )
        let dashboardContent = OperatorDashboardContent(
            runtimeState: shellStore.dashboardContent.runtimeState,
            summary: updatedSummary,
            actionQueue: shellStore.dashboardContent.actionQueue,
            activeJobs: shellStore.dashboardContent.activeJobs,
            recentRuns: shellStore.dashboardContent.recentRuns
        )
        shellStore = StockpileShellStore(
            selectedSection: shellStore.selectedSection,
            path: shellStore.path,
            runs: shellStore.runs,
            dashboardContent: dashboardContent,
            activeFacility: shellStore.activeFacility
        )
    }

    private func applyCompletedRuns(
        _ results: [StockpileResultScreenModel],
        source: CompletedRunsSource
    ) {
        switch captureFeatureStore.phase {
        case .idle, .guidedCapture:
            reviewQueueModel = results.first ?? Self.makeOperationalEmptyReviewModel(configuration: configuration)
            shellStore = Self.makeOperationalShellStore(
                configuration: configuration,
                landingSection: shellStore.selectedSection,
                path: shellStore.path,
                cachedResults: results,
                cachedResultsSource: source
            )
        case .uploadInProgress, .processing, .verifiedResult, .reviewOnlyResult, .blockedResult:
            break
        }
    }

    private func persistCompletedRunIfNeeded(_ resultModel: StockpileResultScreenModel?) {
        guard let resultModel, Self.isCacheableCompletedRun(resultModel) else {
            return
        }

        let updatedResults = Self.normalizedCompletedRuns(
            [resultModel] + Self.loadCachedCompletedRuns(for: configuration)
        )
        Self.storeCachedCompletedRuns(updatedResults, for: configuration)
    }

    private func restorePendingRunRecoveryIfNeeded(
        knownCompletedRuns: [StockpileResultScreenModel]
    ) {
        guard let pendingRun = Self.loadPendingRunRecovery(for: configuration) else {
            return
        }

        let cachedCompletedRuns = Self.loadCachedCompletedRuns(for: configuration)
        let completedRunIDs = Set(
            (cachedCompletedRuns + knownCompletedRuns).compactMap { result -> String? in
                Self.isCacheableCompletedRun(result) ? result.runID : nil
            }
        )

        if let runID = pendingRun.runID,
           completedRunIDs.contains(runID) {
            Self.storePendingRunRecovery(nil, for: configuration)
            return
        }

        captureFeatureStore.resumePendingRunRecovery(pendingRun)
    }

    private func persistPendingRunRecoveryIfNeeded(
        _ pendingRun: CaptureFeaturePendingRunRecoveryState?
    ) {
        Self.storePendingRunRecovery(pendingRun, for: configuration)
    }

    private static func makeOperationalSession(
        configuration: StockpileAppConfiguration,
        launchMode: StockpileAppLaunchMode,
        shellStore: StockpileShellStore?
    ) -> StockpileAppSession {
        let cachedCompletedRuns = loadCachedCompletedRuns(for: configuration)
        let authorizationStore = StockpileOperationalUploadAuthorizationStore()
        let apiService = StockpileOperationalMobileAPIService(
            configuration: configuration.liveMobileAPIConfiguration,
            authorizationStore: authorizationStore
        )
        let uploadService = StockpileOperationalUploadService(
            authorizationStore: authorizationStore,
            defaultHeaders: configuration.liveMobileAPIConfiguration.defaultHeaders
        )
        let markerlessSubmissionCoordinator = StockpileMarkerlessCaptureSubmissionCoordinator(
            submitter: configuration.makeMarkerlessCaptureBundleSubmitter()
        )
        let captureFeatureStore = CaptureFeatureStore.operational(
            configuration: makeOperationalFeatureConfiguration(configuration: configuration),
            cameraSession: makeOperationalCameraSession(configuration: configuration),
            apiService: apiService,
            uploadService: uploadService,
            processingCoordinator: StockpileProcessingRuntimeCoordinator(
                service: apiService,
                pollInterval: configuration.processingPollInterval
            ),
            markerlessSubmissionCoordinator: markerlessSubmissionCoordinator,
            uploadFileDescriptorProvider: {
                try configuration.upload.makeFileDescriptor()
            }
        )
        let initialReviewModel = cachedCompletedRuns.first ?? makeOperationalEmptyReviewModel(configuration: configuration)
        let resolvedShellStore = shellStore ?? makeOperationalShellStore(
            configuration: configuration,
            landingSection: launchMode.landingSection,
            cachedResults: cachedCompletedRuns,
            cachedResultsSource: cachedCompletedRuns.isEmpty ? .none : .cache
        )

        return StockpileAppSession(
            configuration: configuration,
            launchMode: launchMode,
            apiService: apiService,
            captureFeatureStore: captureFeatureStore,
            reviewQueueModel: initialReviewModel,
            shellStore: resolvedShellStore,
            isReady: false
        )
    }

    private static func makeOperationalCameraSession(
        configuration: StockpileAppConfiguration
    ) -> any StockpileCameraCaptureSessionServicing {
        StockpileCameraCaptureSessionLive(
            preferredPosition: configuration.capture.preferredCameraPosition,
            lidarAssistEnabled: configuration.enablesLidarAssist,
            markerlessCaptureEnabled: configuration.capture.markerlessCaptureEnabled
        )
    }

    private static func makeOperationalShellStore(
        configuration: StockpileAppConfiguration,
        landingSection: StockpileShellSection,
        path: [StockpileShellDestination] = [],
        cachedResults: [StockpileResultScreenModel] = [],
        cachedResultsSource: CompletedRunsSource = .none
    ) -> StockpileShellStore {
        let recentRuns = cachedResults.compactMap(dashboardRecentRun(from:))
        let runSummaries = cachedResults.map(runSummary(from:))
        let featuredResult = cachedResults.first
        let activeSiteCount = recentRuns.isEmpty ? 0 : 1
        let dashboardContent = OperatorDashboardContent(
            runtimeState: recentRuns.isEmpty ? .empty : .live,
            summary: OperatorFacilitySummary(
                facilityName: configuration.capture.activeFacilityName,
                operatorLabel: configuration.capture.operatorLabel,
                activeSites: activeSiteCount,
                activeJobs: 0,
                reviewQueue: recentRuns.filter { $0.trustState == .reviewOnly }.count,
                blockedRuns: recentRuns.filter { $0.trustState == .blocked }.count,
                verifiedToday: recentRuns.filter { $0.trustState == .verified }.count,
                lastSyncLabel: initialLastSyncLabel(
                    hasRecentRuns: recentRuns.isEmpty == false,
                    source: cachedResultsSource
                )
            ),
            actionQueue: featuredResult.map(cachedActionQueue(from:)) ?? [],
            activeJobs: [],
            recentRuns: recentRuns
        )

        return StockpileShellStore(
            selectedSection: landingSection,
            path: path,
            runs: runSummaries,
            dashboardContent: dashboardContent,
            activeFacility: configuration.capture.activeFacilityName
        )
    }

    private static func makeOperationalFeatureConfiguration(
        configuration: StockpileAppConfiguration
    ) -> CaptureFeatureConfiguration {
        let capture = configuration.capture

        return CaptureFeatureConfiguration(
            home: makeOperationalHomeContent(configuration: configuration),
            guidedCapture: makeOperationalGuidedCaptureContent(configuration: configuration),
            uploading: makeOperationalUploadProgressContent(configuration: configuration),
            processing: makeOperationalProcessingProgressContent(configuration: configuration),
            verifiedResult: nil,
            reviewOnlyResult: nil,
            blockedResult: nil,
            terminalResultPhase: .blockedResult,
            pipeline: CaptureFeatureConfiguration.CaptureFeaturePipelineConfiguration(
                siteID: capture.siteID,
                materialCode: capture.materialCode,
                densityKgPerM3: capture.densityKgPerM3,
                referenceCountGoal: capture.referenceCountGoal,
                clientBuild: capture.clientBuild,
                backgroundSessionIdentifier: capture.backgroundUploadSessionIdentifier,
                allowsImportedBackupVideo: false,
                allowsConfiguredFallbackCaptureFile: false,
                lidarAssistEnabled: configuration.enablesLidarAssist,
                markerlessCaptureEnabled: capture.markerlessCaptureEnabled
            )
        )
    }

    private static func makeOperationalUploadProgressContent(
        configuration: StockpileAppConfiguration
    ) -> UploadProgressContent {
        UploadProgressContent(
            transferState: .preparing,
            processingState: .idle,
            statusTone: .neutral,
            primaryMessage: "Waiting for the recorded walkaround. The secure upload begins automatically after you finish the live pass."
        )
    }

    private static func makeOperationalProcessingProgressContent(
        configuration: StockpileAppConfiguration
    ) -> UploadProgressContent {
        UploadProgressContent(
            transferState: .complete,
            processingState: .queued,
            statusTone: .neutral,
            primaryMessage: "The recorded walkaround is on the server. Processing updates will appear here as soon as the backend reports them."
        )
    }

    private static func makeOperationalEmptyReviewModel(
        configuration: StockpileAppConfiguration
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: "no-completed-runs",
            pileName: configuration.capture.pileName,
            outcome: .reviewOnly,
            runtimeState: .empty,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: "Queue empty",
                summary: "Completed runs will appear here after a real live capture finishes upload and processing."
            ),
            measurement: nil,
            warnings: [],
            blockers: [],
            recommendedAction: "Record one steady live walkaround to create the first backend-processed result.",
            confidenceLenses: [],
            updatedAt: nil,
            reconstruction: nil
        )
    }

    private static func makeOperationalPendingReviewModel(
        configuration: StockpileAppConfiguration,
        progressContent: UploadProgressContent
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: "processing-live-run",
            pileName: configuration.capture.pileName,
            outcome: .reviewOnly,
            runtimeState: .processing,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: "Processing",
                summary: progressContent.primaryMessage
            ),
            measurement: nil,
            warnings: [],
            blockers: [],
            recommendedAction: "Wait for the backend to finish processing before treating this run as final.",
            confidenceLenses: [],
            updatedAt: nil,
            reconstruction: nil
        )
    }

    private static func makeOperationalRecoveryReviewModel(
        configuration: StockpileAppConfiguration,
        progressContent: UploadProgressContent
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: "live-run-recovery",
            pileName: configuration.capture.pileName,
            outcome: .blocked,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: "Handoff interrupted",
                summary: progressContent.primaryMessage
            ),
            measurement: nil,
            warnings: [],
            blockers: [progressContent.primaryMessage],
            recommendedAction: "Retake the live walkaround after checking network and tagged-reference visibility.",
            confidenceLenses: [],
            updatedAt: nil,
            reconstruction: nil
        )
    }

    private static func makeOperationalHomeContent(
        configuration: StockpileAppConfiguration
    ) -> CaptureHomeContent {
        let capture = configuration.capture

        return CaptureHomeContent(
            siteName: capture.activeFacilityName,
            pileName: capture.pileName,
            materialName: capture.materialName,
            readinessHeadline: "Live capture is ready",
            readinessSummary: "The rear camera records the walkaround directly in this build. Record one steady perimeter pass, keep \(capture.referenceCountGoal) tagged references visible as early as possible, and let the app hand the run straight into upload when coverage looks strong.",
            primaryActionTitle: "Start Live Walkaround",
            quickTips: [
                "Start wide enough to keep the full base of the pile in view before you move.",
                "Walk one continuous toe-boundary sweep instead of stopping and restarting mid-run.",
                "Bring tagged references together early, then keep them recurring as you move.",
            ],
            recentRuns: []
        )
    }

    private static func makeOperationalGuidedCaptureContent(
        configuration: StockpileAppConfiguration
    ) -> GuidedCaptureContent {
        let capture = configuration.capture

        return GuidedCaptureContent(
            pileName: capture.pileName,
            sessionLabel: "Camera idle",
            referencesVisible: 0,
            referenceTarget: capture.referenceCountGoal,
            perimeterCoverage: 0,
            stabilityScore: 0,
            activePrompt: "Open the rear camera and start one steady toe-boundary lap.",
            captureChecks: [
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .needsAttention,
                    detail: "Recording has not started yet. Bring \(capture.referenceCountGoal) tagged references into frame together once the lap begins.",
                    operatorAction: "Start the live recording, then widen the angle until tagged references appear together."
                ),
                GuidedCaptureCheck(
                    title: "Perimeter coverage",
                    status: .needsAttention,
                    detail: "Coverage has not started yet. Use one steady lap around the full toe boundary.",
                    operatorAction: "Begin the lap and keep the toe line visible all the way around the pile."
                ),
                GuidedCaptureCheck(
                    title: "Motion stability",
                    status: .needsAttention,
                    detail: "Recording has not started yet. Keep the phone steady once the live pass begins.",
                    operatorAction: "Start recording first, then settle into a smooth walking pace."
                ),
            ]
        )
    }

    private static func reviewModel(
        configuration: StockpileAppConfiguration,
        phase: CaptureFeaturePhase,
        progressContent: UploadProgressContent,
        currentResult: StockpileResultScreenModel?,
        provisionalResult: StockpileResultScreenModel?,
        existingReviewModel: StockpileResultScreenModel
    ) -> StockpileResultScreenModel {
        switch phase {
        case .verifiedResult, .reviewOnlyResult:
            return currentResult ?? makeOperationalEmptyReviewModel(configuration: configuration)
        case .blockedResult:
            return currentResult ?? makeOperationalRecoveryReviewModel(
                configuration: configuration,
                progressContent: progressContent
            )
        case .uploadInProgress, .processing:
            if let provisionalResult {
                return provisionalResult
            }
            return makeOperationalPendingReviewModel(
                configuration: configuration,
                progressContent: progressContent
            )
        case .idle, .guidedCapture:
            if isCacheableCompletedRun(existingReviewModel) {
                return existingReviewModel
            }
            return makeOperationalEmptyReviewModel(configuration: configuration)
        }
    }

    private static func provisionalReviewModel(
        configuration: StockpileAppConfiguration,
        phase: CaptureFeaturePhase,
        progressContent: UploadProgressContent,
        currentResult: StockpileResultScreenModel?,
        pendingRunRecoveryState: CaptureFeaturePendingRunRecoveryState?
    ) -> StockpileResultScreenModel? {
        guard phase == .processing,
              currentResult == nil,
              progressContent.canOpenResults else {
            return nil
        }

        return StockpileResultScreenModel(
            runID: pendingRunRecoveryState?.runID ?? "processing-live-run",
            pileName: configuration.capture.pileName,
            outcome: .reviewOnly,
            runtimeState: .processing,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: progressContent.processingStatusLabel,
                summary: progressContent.primaryMessage
            ),
            measurement: nil,
            warnings: [],
            blockers: [],
            recommendedAction: progressContent.processingStatusDetail,
            confidenceLenses: [],
            updatedAt: nil,
            reconstruction: nil
        )
    }

    private static func updating(
        _ shellStore: StockpileShellStore,
        configuration: StockpileAppConfiguration,
        phase: CaptureFeaturePhase,
        progressContent: UploadProgressContent,
        resultModel: StockpileResultScreenModel,
        currentResult: StockpileResultScreenModel?
    ) -> StockpileShellStore {
        let recentRuns = updatedRecentRuns(
            existingRuns: shellStore.dashboardContent.recentRuns,
            currentResult: currentResult
        )
        let runs = updatedRunSummaries(
            existingRuns: shellStore.runs,
            currentResult: currentResult
        )
        let dashboardContent = makeDashboardContent(
            configuration: configuration,
            phase: phase,
            progressContent: progressContent,
            resultModel: resultModel,
            currentResult: currentResult,
            existingRecentRuns: recentRuns,
            existingLastSyncLabel: shellStore.dashboardContent.summary.lastSyncLabel
        )

        return StockpileShellStore(
            selectedSection: selectedSection(for: phase, existing: shellStore.selectedSection),
            path: shellStore.path,
            runs: runs,
            dashboardContent: dashboardContent,
            activeFacility: shellStore.activeFacility
        )
    }

    private static func selectedSection(
        for phase: CaptureFeaturePhase,
        existing: StockpileShellSection
    ) -> StockpileShellSection {
        switch phase {
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            return .review
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return existing
        }
    }

    private static func updatedRunSummaries(
        existingRuns: [StockpileRunSummary],
        currentResult: StockpileResultScreenModel?
    ) -> [StockpileRunSummary] {
        guard let currentResult else {
            return existingRuns
        }

        let summary = runSummary(from: currentResult)
        var updatedRuns = existingRuns.filter { $0.id != summary.id }
        updatedRuns.insert(summary, at: 0)
        return updatedRuns
    }

    private static func updatedRecentRuns(
        existingRuns: [OperatorRecentRun],
        currentResult: StockpileResultScreenModel?
    ) -> [OperatorRecentRun] {
        guard let currentResult,
              let recentRun = dashboardRecentRun(from: currentResult)
        else {
            return existingRuns
        }

        var updatedRuns = existingRuns.filter { $0.id != recentRun.id }
        updatedRuns.insert(recentRun, at: 0)
        return Array(updatedRuns.prefix(6))
    }

    private static func makeDashboardContent(
        configuration: StockpileAppConfiguration,
        phase: CaptureFeaturePhase,
        progressContent: UploadProgressContent,
        resultModel: StockpileResultScreenModel,
        currentResult: StockpileResultScreenModel?,
        existingRecentRuns: [OperatorRecentRun],
        existingLastSyncLabel: String
    ) -> OperatorDashboardContent {
        let activeJobs = activeJobs(
            configuration: configuration,
            phase: phase,
            progressContent: progressContent
        )
        let runtimeState = dashboardRuntimeState(
            phase: phase,
            hasRecentRuns: !existingRecentRuns.isEmpty
        )
        let actionQueue = actionQueue(
            phase: phase,
            resultModel: resultModel
        )
        let summary = OperatorFacilitySummary(
            facilityName: configuration.capture.activeFacilityName,
            operatorLabel: configuration.capture.operatorLabel,
            activeSites: (existingRecentRuns.isEmpty && activeJobs.isEmpty) ? 0 : 1,
            activeJobs: activeJobs.count,
            reviewQueue: existingRecentRuns.filter { $0.trustState == .reviewOnly }.count,
            blockedRuns: existingRecentRuns.filter { $0.trustState == .blocked }.count,
            verifiedToday: existingRecentRuns.filter { $0.trustState == .verified }.count,
            lastSyncLabel: lastSyncLabel(
                for: phase,
                hasRecentRuns: !existingRecentRuns.isEmpty,
                currentResult: currentResult,
                existingLabel: existingLastSyncLabel
            )
        )

        return OperatorDashboardContent(
            runtimeState: runtimeState,
            summary: summary,
            actionQueue: actionQueue,
            activeJobs: activeJobs,
            recentRuns: existingRecentRuns
        )
    }

    private static func dashboardRuntimeState(
        phase: CaptureFeaturePhase,
        hasRecentRuns: Bool
    ) -> OperatorDashboardRuntimeState {
        switch phase {
        case .uploadInProgress, .processing:
            return .loading
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            return .live
        case .idle, .guidedCapture:
            return hasRecentRuns ? .live : .empty
        }
    }

    private static func activeJobs(
        configuration: StockpileAppConfiguration,
        phase: CaptureFeaturePhase,
        progressContent: UploadProgressContent
    ) -> [OperatorActiveJob] {
        switch phase {
        case .uploadInProgress:
            return [
                OperatorActiveJob(
                    id: "live-upload",
                    pileName: configuration.capture.pileName,
                    stage: .upload,
                    progress: progressContent.transferState.progress,
                    trustState: .processing,
                    etaLabel: "Working now",
                    detail: progressContent.primaryMessage
                )
            ]
        case .processing:
            return [
                OperatorActiveJob(
                    id: "live-processing",
                    pileName: configuration.capture.pileName,
                    stage: operatorJobStage(from: progressContent.processingState),
                    progress: progressContent.processingState.progress,
                    trustState: .processing,
                    etaLabel: "Awaiting backend",
                    detail: progressContent.primaryMessage
                )
            ]
        case .idle, .guidedCapture, .verifiedResult, .reviewOnlyResult, .blockedResult:
            return []
        }
    }

    private static func operatorJobStage(from state: ProcessingStageState) -> OperatorJobStage {
        switch state {
        case .idle, .queued, .preparingFrames:
            return .upload
        case .detectingReferences:
            return .referenceScan
        case .reconstructing:
            return .reconstruction
        case .calibrating:
            return .calibration
        case .computingVolume, .reviewReady, .blocked:
            return .reporting
        }
    }

    private static func actionQueue(
        phase: CaptureFeaturePhase,
        resultModel: StockpileResultScreenModel
    ) -> [OperatorDashboardAction] {
        switch phase {
        case .verifiedResult:
            return [
                OperatorDashboardAction(
                    id: "share-\(resultModel.runID)",
                    title: "Share verified report",
                    detail: "This run passed the live backend checks and is ready for release.",
                    kind: .share,
                    trustState: .verified
                )
            ]
        case .reviewOnlyResult:
            return [
                OperatorDashboardAction(
                    id: "review-\(resultModel.runID)",
                    title: "Cross-check latest run",
                    detail: resultModel.recommendedAction,
                    kind: .review,
                    trustState: .reviewOnly
                )
            ]
        case .blockedResult:
            return [
                OperatorDashboardAction(
                    id: "recapture-\(resultModel.runID)",
                    title: "Plan recapture",
                    detail: resultModel.recommendedAction,
                    kind: .recapture,
                    trustState: .blocked
                )
            ]
        case .uploadInProgress, .processing:
            return [
                OperatorDashboardAction(
                    id: "monitor-live-job",
                    title: "Track live processing",
                    detail: resultModel.confidence.summary,
                    kind: .monitor,
                    trustState: .processing
                )
            ]
        case .idle, .guidedCapture:
            return cachedActionQueue(from: resultModel)
        }
    }

    private static func lastSyncLabel(
        for phase: CaptureFeaturePhase,
        hasRecentRuns: Bool,
        currentResult: StockpileResultScreenModel?,
        existingLabel: String
    ) -> String {
        switch phase {
        case .uploadInProgress, .processing:
            return "Syncing with backend"
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            return "Updated just now"
        case .idle, .guidedCapture:
            guard hasRecentRuns else {
                return "Awaiting first live run"
            }
            if let currentResult, isCacheableCompletedRun(currentResult) {
                return "Updated just now"
            }

            let trimmedExistingLabel = existingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedExistingLabel.isEmpty ? "Loaded from saved runs" : trimmedExistingLabel
        }
    }

    private static func initialLastSyncLabel(
        hasRecentRuns: Bool,
        source: CompletedRunsSource
    ) -> String {
        guard hasRecentRuns else {
            return "Awaiting first live run"
        }

        switch source {
        case .none:
            return "Awaiting first live run"
        case .cache:
            return "Loaded from saved runs"
        case .backend:
            return "Refreshed from backend"
        }
    }

    private static func runSummary(from resultModel: StockpileResultScreenModel) -> StockpileRunSummary {
        StockpileRunSummary(
            id: resultModel.runID,
            pileName: resultModel.pileName,
            statusLabel: statusLabel(for: resultModel.outcome),
            confidenceLabel: "\(resultModel.confidence.score)/100 \(resultModel.confidence.label)"
        )
    }

    private static func dashboardRecentRun(from resultModel: StockpileResultScreenModel) -> OperatorRecentRun? {
        guard isCacheableCompletedRun(resultModel),
              resultModel.measurement != nil || resultModel.outcome == .blocked || resultModel.outcome == .reviewOnly else {
            return nil
        }

        return OperatorRecentRun(
            id: resultModel.runID,
            pileName: resultModel.pileName,
            trustState: dashboardTrustState(for: resultModel.outcome),
            confidenceLabel: "\(resultModel.confidence.score)/100 \(resultModel.confidence.label)",
            volumeLabel: resultModel.measurement.map { "\($0.volumeM3.formatted(.number.precision(.fractionLength(0)))) m³" },
            relativeTimeLabel: relativeTimeLabel(for: resultModel.updatedAt),
            detail: resultModel.recommendedAction
        )
    }

    private static func dashboardTrustState(for outcome: StockpileResultOutcome) -> OperatorDashboardTrustState {
        switch outcome {
        case .verified:
            return .verified
        case .reviewOnly:
            return .reviewOnly
        case .blocked:
            return .blocked
        }
    }

    private static func statusLabel(for outcome: StockpileResultOutcome) -> String {
        switch outcome {
        case .verified:
            return "Ready to release"
        case .reviewOnly:
            return "Needs review"
        case .blocked:
            return "Recapture needed"
        }
    }

    private static func makeResultModel(from payload: StockpileResultPayload) -> StockpileResultScreenModel {
        StockpileResultModelFactory.makeResultScreenModel(from: payload)
    }

    private static func cachedActionQueue(from resultModel: StockpileResultScreenModel) -> [OperatorDashboardAction] {
        guard isCacheableCompletedRun(resultModel) else {
            return []
        }

        switch resultModel.outcome {
        case .verified:
            return [
                OperatorDashboardAction(
                    id: "share-\(resultModel.runID)",
                    title: "Share verified report",
                    detail: "This run already cleared the backend checks and is ready for release.",
                    kind: .share,
                    trustState: .verified
                )
            ]
        case .reviewOnly:
            return [
                OperatorDashboardAction(
                    id: "review-\(resultModel.runID)",
                    title: "Cross-check latest run",
                    detail: resultModel.recommendedAction,
                    kind: .review,
                    trustState: .reviewOnly
                )
            ]
        case .blocked:
            return [
                OperatorDashboardAction(
                    id: "recapture-\(resultModel.runID)",
                    title: "Plan recapture",
                    detail: resultModel.recommendedAction,
                    kind: .recapture,
                    trustState: .blocked
                )
            ]
        }
    }

    private static func isCacheableCompletedRun(_ resultModel: StockpileResultScreenModel) -> Bool {
        guard resultModel.runtimeState == .ready else {
            return false
        }

        let normalizedRunID = resultModel.runID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedRunID.isEmpty == false else {
            return false
        }

        let placeholderRunIDs = [
            "no-completed-runs",
            "processing-live-run",
            "live-run-recovery",
        ]
        guard placeholderRunIDs.contains(normalizedRunID) == false else {
            return false
        }

        return normalizedRunID.contains("preview") == false
    }

    private static func relativeTimeLabel(for updatedAt: Date?) -> String {
        guard let updatedAt else {
            return "Recent result"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    private static func normalizedCompletedRuns(_ results: [StockpileResultScreenModel]) -> [StockpileResultScreenModel] {
        var seenRunIDs: Set<String> = []
        var normalizedResults: [StockpileResultScreenModel] = []
        normalizedResults.reserveCapacity(min(results.count, maxCachedCompletedRuns))

        for result in results where isCacheableCompletedRun(result) {
            guard seenRunIDs.insert(result.runID).inserted else {
                continue
            }

            normalizedResults.append(result)
            if normalizedResults.count == maxCachedCompletedRuns {
                break
            }
        }

        return normalizedResults
    }

    private static func loadCachedCompletedRuns(
        for configuration: StockpileAppConfiguration,
        defaults: UserDefaults = .standard
    ) -> [StockpileResultScreenModel] {
        let cacheKey = completedRunsCacheKey(for: configuration)
        guard let data = defaults.data(forKey: cacheKey) else {
            return []
        }

        guard let decodedResults = try? JSONDecoder().decode([StockpileResultScreenModel].self, from: data) else {
            defaults.removeObject(forKey: cacheKey)
            return []
        }

        let normalizedResults = normalizedCompletedRuns(decodedResults)
        if normalizedResults != decodedResults {
            storeCachedCompletedRuns(normalizedResults, for: configuration, defaults: defaults)
        }
        return normalizedResults
    }

    private static func storeCachedCompletedRuns(
        _ results: [StockpileResultScreenModel],
        for configuration: StockpileAppConfiguration,
        defaults: UserDefaults = .standard
    ) {
        let normalizedResults = normalizedCompletedRuns(results)
        let cacheKey = completedRunsCacheKey(for: configuration)
        guard normalizedResults.isEmpty == false else {
            defaults.removeObject(forKey: cacheKey)
            return
        }

        guard let data = try? JSONEncoder().encode(normalizedResults) else {
            return
        }

        defaults.set(data, forKey: cacheKey)
    }

    private static func loadPendingRunRecovery(
        for configuration: StockpileAppConfiguration,
        defaults: UserDefaults = .standard
    ) -> CaptureFeaturePendingRunRecoveryState? {
        let cacheKey = pendingRunRecoveryKey(for: configuration)
        guard let data = defaults.data(forKey: cacheKey) else {
            return nil
        }

        guard let pendingRun = try? JSONDecoder().decode(CaptureFeaturePendingRunRecoveryState.self, from: data) else {
            defaults.removeObject(forKey: cacheKey)
            return nil
        }

        return pendingRun
    }

    private static func storePendingRunRecovery(
        _ pendingRun: CaptureFeaturePendingRunRecoveryState?,
        for configuration: StockpileAppConfiguration,
        defaults: UserDefaults = .standard
    ) {
        let cacheKey = pendingRunRecoveryKey(for: configuration)
        guard let pendingRun else {
            defaults.removeObject(forKey: cacheKey)
            return
        }

        guard let data = try? JSONEncoder().encode(pendingRun) else {
            return
        }

        defaults.set(data, forKey: cacheKey)
    }

    private static func completedRunsCacheKey(
        for configuration: StockpileAppConfiguration
    ) -> String {
        [
            completedRunsCacheKeyPrefix,
            completedRunsCacheSchemaVersion,
            configuration.environmentName,
            configuration.apiBaseURL.absoluteString,
            configuration.capture.siteID,
            configuration.capture.activeFacilityName,
        ].joined(separator: "|")
    }

    private static func pendingRunRecoveryKey(
        for configuration: StockpileAppConfiguration
    ) -> String {
        [
            pendingRunRecoveryKeyPrefix,
            pendingRunRecoverySchemaVersion,
            configuration.environmentName,
            configuration.apiBaseURL.absoluteString,
            configuration.capture.siteID,
            configuration.capture.activeFacilityName,
        ].joined(separator: "|")
    }
}

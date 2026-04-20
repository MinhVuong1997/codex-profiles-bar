import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarRootView: View {
    @ObservedObject var model: CodexProfilesViewModel
    var isDetached = false
    let resolvedColorScheme: ColorScheme
    @AppStorage(Preferences.showIDsKey) private var showIDs = false
    @AppStorage(Preferences.compactModeKey) private var compactMode = false
    @AppStorage(Preferences.groupingKey) private var groupingRaw = ProfileGrouping.none.rawValue
    @AppStorage(Preferences.accentRedKey) private var accentRed = 0.15
    @AppStorage(Preferences.accentGreenKey) private var accentGreen = 0.44
    @AppStorage(Preferences.accentBlueKey) private var accentBlue = 0.95
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var showImportPicker = false
    @State private var showSaveSheet = false
    @State private var showDoctorSheet = false
    @State private var showInboxSheet = false
    @State private var showQuickSwitch = false
    @State private var selectedFilter: ProfileFilter = .all
    @State private var searchText = ""
    @State private var quickSwitchQuery = ""
    @State private var quickSwitchSelectionIndex = 0
    @State private var bulkSelectionMode = false
    @State private var bulkSelectedProfileIDs = Set<String>()
    @State private var selectedProfileID: String?
    @State private var labelEditorTarget: ProfileStatus?
    @State private var deleteTarget: ProfileStatus?
    @State private var bulkDeleteTargets: [ProfileStatus] = []
    @State private var switchTarget: ProfileStatus?
    @State private var isImporting = false
    @State private var isExportingAll = false
    @State private var clearingLabelProfileID: String?
    @State private var localKeyMonitor: Any?
    @State private var localMouseMonitor: Any?
    @State private var pendingCenteredScrollProfileID: String?
    @State private var pendingTopScrollRequest = 0
    @State private var isTopScrollPending = false
    private let scrollTopAnchorID = "profiles-scroll-top"

    private var palette: PanelPalette {
        PanelPalette.resolve(for: resolvedColorScheme, accent: Color(red: accentRed, green: accentGreen, blue: accentBlue))
    }

    private var grouping: ProfileGrouping {
        ProfileGrouping(rawValue: groupingRaw) ?? .none
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundStart, palette.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                header

                if let banner = model.banner {
                    BannerView(message: banner) {
                        model.dismissBanner()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                actionBar

                content
            }
            .padding(16)

            if activeOverlayKind != nil {
                palette.shadow.opacity(0.9)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        dismissActiveOverlay()
                    }
            }

            if showDoctorSheet {
                DoctorOverlay(model: model) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showDoctorSheet = false
                    }
                }
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }

            if showInboxSheet {
                NotificationInboxOverlay(model: model) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showInboxSheet = false
                    }
                }
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }

            if showSaveSheet {
                SaveProfileOverlay(model: model) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showSaveSheet = false
                    }
                }
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if let profile = labelEditorTarget {
                EditLabelOverlay(model: model, profile: profile) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        labelEditorTarget = nil
                    }
                }
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if let profile = deleteTarget {
                DeleteProfileOverlay(model: model, profile: profile, onClose: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        deleteTarget = nil
                    }
                })
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if !bulkDeleteTargets.isEmpty {
                DeleteProfilesOverlay(model: model, profiles: bulkDeleteTargets, onClose: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        bulkDeleteTargets = []
                    }
                })
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if let profile = switchTarget {
                UnsavedSwitchOverlay(model: model, profile: profile, onClose: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        switchTarget = nil
                    }
                })
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if let prompt = model.codexRelaunchPrompt {
                CodexRelaunchOverlay(model: model, prompt: prompt) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        model.dismissCodexRelaunchPrompt()
                    }
                }
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if showQuickSwitch {
                QuickSwitchOverlay(
                    query: $quickSwitchQuery,
                    profiles: quickSwitchResults,
                    selectedIndex: $quickSwitchSelectionIndex,
                    onChoose: { profile in
                        triggerQuickSwitch(profile)
                    },
                    onClose: {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            showQuickSwitch = false
                        }
                    }
                )
                .padding(14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(3)
            }

        }
        .environment(\.colorScheme, resolvedColorScheme)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: model.banner?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showDoctorSheet)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showInboxSheet)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showSaveSheet)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showQuickSwitch)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: labelEditorTarget?.stableID)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: deleteTarget?.stableID)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: bulkDeleteTargets.map(\.stableID))
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: switchTarget?.stableID)
        .frame(
            minWidth: 460,
            idealWidth: isDetached ? 540 : 460,
            maxWidth: isDetached ? .infinity : 460,
            minHeight: 640,
            idealHeight: isDetached ? 760 : 640,
            maxHeight: isDetached ? .infinity : 640
        )
        .onAppear {
            installLocalKeyMonitorIfNeeded()
            installLocalMouseMonitorIfNeeded()
            ensureValidSelection()
            requestTopScroll()
        }
        .onDisappear {
            removeLocalKeyMonitor()
            removeLocalMouseMonitor()
        }
        .onChange(of: navigableProfiles.map(\.stableID)) { _, ids in
            ensureValidSelection()
            bulkSelectedProfileIDs = bulkSelectedProfileIDs.intersection(Set(ids))
        }
        .onChange(of: model.profiles.map(\.stableID)) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: quickSwitchResults.map(\.stableID)) { _, ids in
            if ids.isEmpty {
                quickSwitchSelectionIndex = 0
            } else {
                quickSwitchSelectionIndex = min(quickSwitchSelectionIndex, ids.count - 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleProfilesShortcut)) { _ in
            Task { await model.cycleToNextProfile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            if isDetached {
                guard window.identifier?.rawValue == "profiles-panel" else { return }
            } else if window.identifier?.rawValue == "profiles-panel" {
                return
            }
            requestTopScroll()
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                isImporting = true
                Task {
                    _ = await model.importBundle(from: url)
                    await MainActor.run {
                        isImporting = false
                    }
                }
            case .failure(let error):
                isImporting = false
                model.banner = BannerMessage(
                    tone: .error,
                    title: "Import cancelled",
                    body: error.localizedDescription
                )
            }
        }
    }

    private var activeOverlayKind: String? {
        if showDoctorSheet { return "doctor" }
        if showInboxSheet { return "inbox" }
        if showSaveSheet { return "save" }
        if showQuickSwitch { return "quick-switch" }
        if labelEditorTarget != nil { return "label" }
        if deleteTarget != nil { return "delete" }
        if !bulkDeleteTargets.isEmpty { return "bulk-delete" }
        if switchTarget != nil { return "switch" }
        if model.codexRelaunchPrompt != nil { return "relaunch" }
        return nil
    }

    private func dismissActiveOverlay() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            if switchTarget != nil {
                switchTarget = nil
            } else if !bulkDeleteTargets.isEmpty {
                bulkDeleteTargets = []
            } else if deleteTarget != nil {
                deleteTarget = nil
            } else if labelEditorTarget != nil {
                labelEditorTarget = nil
            } else if model.codexRelaunchPrompt != nil {
                model.dismissCodexRelaunchPrompt()
            } else if showQuickSwitch {
                showQuickSwitch = false
            } else if showSaveSheet {
                showSaveSheet = false
            } else if showInboxSheet {
                showInboxSheet = false
            } else if showDoctorSheet {
                showDoctorSheet = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Codex Profiles Bar")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)

                    RefreshActivityBadge(isRefreshing: model.isRefreshingProfiles)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                RefreshButton(isRefreshing: model.isRefreshingProfiles) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRefreshingProfiles)
                .help(model.isRefreshingProfiles ? "Refreshing profiles…" : "Refresh profiles")

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showInboxSheet = true
                    }
                    model.markAllInboxItemsRead()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: model.unreadInboxCount > 0 ? "bell.badge.fill" : "bell")

                        if model.unreadInboxCount > 0 {
                            Text("\(min(model.unreadInboxCount, 9))")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(palette.warning))
                                .offset(x: 5, y: -5)
                        }
                    }
                }
                .buttonStyle(IconButtonStyle())
                .help(model.unreadInboxCount > 0 ? "Open inbox (\(model.unreadInboxCount) unread)" : "Open notification inbox")

                if !isDetached {
                    Button {
                        openDetachedPanel()
                    } label: {
                        Image(systemName: "macwindow")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Open detachable panel")
                }

                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IconButtonStyle())
                .help("Open settings")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(IconButtonStyle())
                .help("Exit app")
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ActionButton(title: "Save Current", symbol: "square.and.arrow.down") {
                    showSaveSheet = true
                }
                .disabled(model.isLoading)

                ActionButton(title: isImporting ? "Importing…" : "Import", symbol: "square.and.arrow.down.on.square", isLoading: isImporting) {
                    showImportPicker = true
                }
                .disabled(model.isLoading || isImporting || isExportingAll)

                ActionButton(title: isExportingAll ? "Exporting…" : "Export All", symbol: "square.and.arrow.up", isLoading: isExportingAll) {
                    Task {
                        if let url = presentSavePanel(suggestedName: "codex-profile-bundle.json") {
                            isExportingAll = true
                            _ = await model.exportProfiles(
                                ids: model.savedProfiles.compactMap(\.id),
                                to: url,
                                descriptor: "all saved profiles"
                            )
                            isExportingAll = false
                        }
                    }
                }
                .disabled(model.savedProfiles.isEmpty || model.isLoading || isImporting || isExportingAll)

                ActionButton(title: "Doctor", symbol: "stethoscope") {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showDoctorSheet = true
                    }
                    Task { await model.loadDoctorReport() }
                }
                .disabled(model.isLoading || isImporting || isExportingAll)
            }

            HStack(spacing: 10) {
                SearchField(text: $searchText, palette: palette)
                filterCountBadge
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        bulkSelectionMode.toggle()
                    }
                    if !bulkSelectionMode {
                        bulkSelectedProfileIDs.removeAll()
                    }
                } label: {
                    Text(bulkSelectionMode ? "Done" : "Select")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(bulkSelectionMode ? Color.white : palette.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(bulkSelectionMode ? palette.accent : palette.subtleFill)
                                .overlay(
                                    Capsule()
                                        .stroke(bulkSelectionMode ? palette.accent.opacity(0.4) : palette.cardStroke, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.profiles.isEmpty {
            Spacer()
            ProgressView("Loading profiles…")
                .tint(palette.primaryText)
                .foregroundStyle(palette.primaryText)
            Spacer()
        } else if model.profiles.isEmpty {
            Spacer()
            EmptyStateView(
                title: "No profiles yet",
                message: "Save the current auth first, then the menu bar will show every saved profile with its status and a one-click switch button."
            )
            Spacer()
        } else {
            VStack(spacing: 0) {
                filterBarHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            Color.clear
                                .frame(height: 1)
                                .id(scrollTopAnchorID)

                            if let currentProfile = model.currentProfile {
                                ActiveProfileSpotlightCard(
                                    profile: currentProfile,
                                    showID: showIDs,
                                    isFavorite: model.isFavorite(currentProfile),
                                    sparklineValues: model.usageHistoryByProfileID[currentProfile.id ?? ""]?.sparklinePercentages ?? [],
                                    healthBadges: healthBadges(for: currentProfile),
                                    recommendation: model.recommendedSwitch,
                                    isRestartingCodex: model.isRestartingCodex,
                                    onToggleFavorite: {
                                        model.toggleFavorite(currentProfile)
                                    },
                                    onReopen: {
                                        Task { _ = await model.restartCodex() }
                                    },
                                    onSwitchRecommended: {
                                        guard let recommendation = model.recommendedSwitch,
                                              let profile = model.savedProfiles.first(where: { $0.id == recommendation.profileID }) else {
                                            return
                                        }
                                        selectedProfileID = profile.stableID
                                        if model.hasUnsavedCurrentProfile {
                                            switchTarget = profile
                                        } else {
                                            Task { await model.switchToProfile(profile, mode: .standard) }
                                        }
                                    }
                                )
                            }

                            if let aggregateUsage = model.aggregateUsage {
                                AggregateUsageCard(summary: aggregateUsage, palette: palette)
                            }

                            if bulkSelectionMode {
                                bulkActionBar
                            }

                            if let lastRefresh = model.lastRefresh {
                                HStack {
                                    Text(model.isRefreshingProfiles ? "Refreshing profiles…" : "Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(model.isRefreshingProfiles ? palette.success : palette.tertiaryText)
                                        .contentTransition(.opacity)
                                    Spacer()
                                }
                            } else if model.isRefreshingProfiles {
                                HStack {
                                    Text("Refreshing profiles…")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(palette.success)
                                    Spacer()
                                }
                            }

                            if navigableProfiles.isEmpty {
                                EmptyStateView(
                                    title: "No additional profiles match this filter",
                                    message: "Try switching back to All, clearing search, or saving more profiles. Your active session stays pinned above for quick access."
                                )
                                .padding(.top, 30)
                            } else {
                                ForEach(groupedProfiles) { group in
                                    if grouping == .plan {
                                        Text(group.title)
                                            .font(.system(.caption, design: .monospaced, weight: .bold))
                                            .foregroundStyle(palette.tertiaryText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 4)
                                    }

                                    ForEach(group.profiles, id: \.stableID) { profile in
                                        ProfileCard(
                                            profile: profile,
                                            showID: showIDs,
                                            isFavorite: model.isFavorite(profile),
                                            isCompact: compactMode,
                                            sparklineValues: model.usageHistoryByProfileID[profile.id ?? ""]?.sparklinePercentages ?? [],
                                            healthBadges: healthBadges(for: profile),
                                            isSelected: selectedProfileID == profile.stableID,
                                            isBulkMode: bulkSelectionMode,
                                            isBulkSelected: bulkSelectedProfileIDs.contains(profile.stableID),
                                            isSwitching: model.switchingProfileID == profile.id,
                                            isSwitchDisabled: model.switchingProfileID != nil,
                                            isClearingLabel: clearingLabelProfileID == profile.stableID,
                                            onSwitch: {
                                                selectedProfileID = profile.stableID
                                                if model.hasUnsavedCurrentProfile {
                                                    switchTarget = profile
                                                } else {
                                                    Task { await model.switchToProfile(profile, mode: .standard) }
                                                }
                                            },
                                            onToggleFavorite: {
                                                selectedProfileID = profile.stableID
                                                model.toggleFavorite(profile)
                                            },
                                            onSelect: {
                                                if bulkSelectionMode {
                                                    toggleBulkSelection(for: profile)
                                                } else {
                                                    selectedProfileID = profile.stableID
                                                }
                                            },
                                            onEditLabel: {
                                                selectedProfileID = profile.stableID
                                                labelEditorTarget = profile
                                            },
                                            onClearLabel: {
                                                guard clearingLabelProfileID == nil else { return }
                                                selectedProfileID = profile.stableID
                                                clearingLabelProfileID = profile.stableID
                                                Task {
                                                    _ = await model.clearLabel(for: profile)
                                                    await MainActor.run {
                                                        clearingLabelProfileID = nil
                                                    }
                                                }
                                            },
                                            onExport: {
                                                selectedProfileID = profile.stableID
                                                Task {
                                                    guard let id = profile.id else { return }
                                                    let suggestedName = profile.label ?? profile.id ?? "codex-profile"
                                                    if let url = presentSavePanel(suggestedName: "\(suggestedName).json") {
                                                        await model.exportProfiles(ids: [id], to: url, descriptor: profile.primaryText)
                                                    }
                                                }
                                            },
                                            onDelete: {
                                                selectedProfileID = profile.stableID
                                                deleteTarget = profile
                                            },
                                            onToggleBulkSelection: {
                                                toggleBulkSelection(for: profile)
                                            }
                                        )
                                        .id(profile.stableID)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: pendingCenteredScrollProfileID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        DispatchQueue.main.async {
                            pendingCenteredScrollProfileID = nil
                        }
                    }
                    .onChange(of: pendingTopScrollRequest) { _, _ in
                        scrollToTop(using: proxy, animated: false)
                    }
                    .onChange(of: navigableProfiles.map(\.stableID)) { _, _ in
                        guard isTopScrollPending else { return }
                        scrollToTop(using: proxy, animated: false)
                        DispatchQueue.main.async {
                            isTopScrollPending = false
                        }
                    }
                }
            }
        }
    }

    private func scrollToTop(using proxy: ScrollViewProxy, animated: Bool = true) {
        let performScroll = {
            proxy.scrollTo(scrollTopAnchorID, anchor: .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                performScroll()
            }
        } else {
            performScroll()
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    performScroll()
                }
            } else {
                performScroll()
            }
        }
    }

    private func requestTopScroll() {
        isTopScrollPending = true
        pendingTopScrollRequest += 1
    }

    private func presentSavePanel(suggestedName: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openSettingsWindow() {
        resignTextInputFocus()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)

            let settingsWindow = NSApp.windows.first(where: { window in
                let titleMatch = window.title.localizedCaseInsensitiveContains("settings")
                let identifierMatch = window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
                return titleMatch || identifierMatch
            }) ?? NSApp.windows.last

            settingsWindow?.level = .normal
            settingsWindow?.makeKeyAndOrderFront(nil)
            settingsWindow?.orderFrontRegardless()
        }
    }

    private func openDetachedPanel() {
        resignTextInputFocus()
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "profiles-panel")
        NSApp.activate(ignoringOtherApps: true)

        @MainActor
        func focusPanel() {
            let panelWindow = NSApp.windows.first(where: { window in
                window.identifier?.rawValue == "profiles-panel"
                    || window.title.localizedCaseInsensitiveContains("profiles panel")
                    || !existingWindows.contains(ObjectIdentifier(window))
            })

            for window in NSApp.windows where window != panelWindow && window.title.isEmpty {
                window.orderOut(nil)
            }

            panelWindow?.level = .normal
            panelWindow?.collectionBehavior.insert(.moveToActiveSpace)
            panelWindow?.makeMain()
            panelWindow?.makeKeyAndOrderFront(nil)
        }

        Task { @MainActor in
            focusPanel()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            focusPanel()
        }
    }

    private func installLocalKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleLocalKeyEvent(event)
        }
    }

    private func installLocalMouseMonitorIfNeeded() {
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleLocalMouseEvent(event)
        }
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func removeLocalMouseMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func handleLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isEditingTextInput {
            return event
        }

        if modifiers == [.command], characters == "k" {
            toggleQuickSwitch()
            return nil
        }

        guard activeOverlayKind == nil || showQuickSwitch else {
            return event
        }

        if showQuickSwitch {
            switch event.keyCode {
            case 125:
                if quickSwitchSelectionIndex < max(0, quickSwitchResults.count - 1) {
                    quickSwitchSelectionIndex += 1
                }
                return nil
            case 126:
                if quickSwitchSelectionIndex > 0 {
                    quickSwitchSelectionIndex -= 1
                }
                return nil
            case 36:
                if quickSwitchResults.indices.contains(quickSwitchSelectionIndex) {
                    triggerQuickSwitch(quickSwitchResults[quickSwitchSelectionIndex])
                }
                return nil
            case 53:
                showQuickSwitch = false
                return nil
            default:
                return event
            }
        }

        if bulkSelectionMode {
            switch event.keyCode {
            case 125:
                moveSelection(delta: 1)
                return nil
            case 126:
                moveSelection(delta: -1)
                return nil
            case 49:
                if let selectedProfile {
                    toggleBulkSelection(for: selectedProfile)
                }
                return nil
            case 51:
                presentBulkDelete()
                return nil
            case 53:
                bulkSelectionMode = false
                bulkSelectedProfileIDs.removeAll()
                return nil
            default:
                return event
            }
        }

        switch event.keyCode {
        case 125:
            moveSelection(delta: 1)
            return nil
        case 126:
            moveSelection(delta: -1)
            return nil
        case 36, 49:
            activateSelectedProfile()
            return nil
        case 51:
            deleteSelectedProfile()
            return nil
        default:
            break
        }

        if modifiers == [.command, .shift], characters == "e" {
            exportSelectedProfile()
            return nil
        }

        return event
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard isEditingTextInput else { return event }
        guard let window = event.window else { return event }

        let pointInWindow = event.locationInWindow
        let pointInContent = window.contentView?.convert(pointInWindow, from: nil) ?? pointInWindow
        let hitView = window.contentView?.hitTest(pointInContent)

        if !isTextInputView(hitView) {
            DispatchQueue.main.async {
                resignTextInputFocus()
            }
        }

        return event
    }

    private var isEditingTextInput: Bool {
        let responders = [NSApp.keyWindow?.firstResponder, NSApp.mainWindow?.firstResponder]
        return responders.contains { responder in
            guard let responder else { return false }
            if responder is NSTextView {
                return true
            }
            if let view = responder as? NSView, isTextInputView(view) {
                return true
            }
            return false
        }
    }

    private func isTextInputView(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if view is NSTextField || view is NSSearchField || view is NSTextView {
            return true
        }
        return isTextInputView(view.superview)
    }

    private func resignTextInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private func toggleQuickSwitch() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            showQuickSwitch.toggle()
        }
        if showQuickSwitch {
            quickSwitchQuery = ""
            quickSwitchSelectionIndex = 0
        }
    }

    private func ensureValidSelection() {
        if let selectedProfileID, navigableProfiles.contains(where: { $0.stableID == selectedProfileID }) {
            return
        }
        selectedProfileID = navigableProfiles.first?.stableID
    }

    private func moveSelection(delta: Int) {
        guard !navigableProfiles.isEmpty else { return }
        let currentIndex = navigableProfiles.firstIndex(where: { $0.stableID == selectedProfileID }) ?? 0
        let nextIndex = max(0, min(navigableProfiles.count - 1, currentIndex + delta))
        selectedProfileID = navigableProfiles[nextIndex].stableID
        pendingCenteredScrollProfileID = selectedProfileID
    }

    private func activateSelectedProfile() {
        guard !bulkSelectionMode else { return }
        guard let profile = selectedProfile else { return }
        guard !profile.isCurrent else { return }
        if model.hasUnsavedCurrentProfile {
            switchTarget = profile
        } else if profile.canSwitch {
            Task { await model.switchToProfile(profile, mode: .standard) }
        }
    }

    private func exportSelectedProfile() {
        guard let profile = selectedProfile, let id = profile.id else { return }
        Task {
            let suggestedName = profile.label ?? profile.id ?? "codex-profile"
            if let url = presentSavePanel(suggestedName: "\(suggestedName).json") {
                await model.exportProfiles(ids: [id], to: url, descriptor: profile.primaryText)
            }
        }
    }

    private func deleteSelectedProfile() {
        guard !bulkSelectionMode else {
            presentBulkDelete()
            return
        }
        guard let profile = selectedProfile, profile.isSaved else { return }
        deleteTarget = profile
    }

    private func toggleBulkSelection(for profile: ProfileStatus) {
        if bulkSelectedProfileIDs.contains(profile.stableID) {
            bulkSelectedProfileIDs.remove(profile.stableID)
        } else {
            bulkSelectedProfileIDs.insert(profile.stableID)
        }
        selectedProfileID = profile.stableID
    }

    private func presentBulkDelete() {
        let targets = selectedBulkProfiles.filter(\.isSaved)
        guard !targets.isEmpty else { return }
        bulkDeleteTargets = targets
    }

    private func triggerQuickSwitch(_ profile: ProfileStatus) {
        selectedProfileID = profile.stableID
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            showQuickSwitch = false
        }
        guard !profile.isCurrent else { return }
        if model.hasUnsavedCurrentProfile {
            switchTarget = profile
        } else {
            Task { await model.switchToProfile(profile, mode: .standard) }
        }
    }

    private var filteredProfiles: [ProfileStatus] {
        let baseProfiles: [ProfileStatus]

        switch selectedFilter {
        case .all:
            baseProfiles = model.profiles
        case .hasUsage:
            baseProfiles = model.profiles.filter(\.hasRemainingUsage)
        case .favorites:
            baseProfiles = model.profiles.filter { model.isFavorite($0) }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseProfiles }

        let normalizedQuery = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return baseProfiles.filter { profile in
            profile.searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var navigableProfiles: [ProfileStatus] {
        filteredProfiles.filter { !$0.isCurrent }
    }

    private var groupedProfiles: [ProfileGroup] {
        switch grouping {
        case .none:
            return [ProfileGroup(title: "All", profiles: navigableProfiles)]
        case .plan:
            let grouped = Dictionary(grouping: navigableProfiles, by: \.planGroupTitle)
            return grouped.keys.sorted().map { key in
                ProfileGroup(title: key, profiles: grouped[key] ?? [])
            }
        }
    }

    private var quickSwitchResults: [ProfileStatus] {
        let trimmed = quickSwitchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.profiles }
        let normalizedQuery = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return model.profiles.filter { $0.searchableText.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    private var selectedProfile: ProfileStatus? {
        if let selectedProfileID {
            return navigableProfiles.first(where: { $0.stableID == selectedProfileID })
        }
        return navigableProfiles.first
    }

    private var selectedBulkProfiles: [ProfileStatus] {
        model.profiles.filter { bulkSelectedProfileIDs.contains($0.stableID) }
    }

    private var shouldRemoveFavoritesInBulk: Bool {
        let selectedIDs = Set(selectedBulkProfiles.compactMap(\.id))
        return !selectedIDs.isEmpty && selectedIDs.allSatisfy { id in
            model.savedProfiles.contains(where: { $0.id == id && model.isFavorite($0) })
        }
    }

    private func healthBadges(for profile: ProfileStatus) -> [ProfileHealthBadgeDescriptor] {
        var badges = [ProfileHealthBadgeDescriptor]()

        if profile.isCurrent {
            badges.append(.init(title: "Active", symbol: "checkmark.circle.fill", tone: .success))
        }

        if profile.error != nil {
            badges.append(.init(title: "Needs repair", symbol: "wrench.and.screwdriver.fill", tone: .error))
        } else if profile.isUsageDepleted {
            badges.append(.init(title: "Depleted", symbol: "bolt.horizontal.circle.fill", tone: .error))
        } else if profile.isLowUsage(threshold: model.notificationThreshold) {
            badges.append(.init(title: "Low usage", symbol: "exclamationmark.triangle.fill", tone: .warning))
        }

        if profile.resetsSoon {
            badges.append(.init(title: "Resets soon", symbol: "clock.badge.exclamationmark.fill", tone: .info))
        }

        if profile.isCurrent && !profile.isSaved {
            badges.append(.init(title: "Unsaved", symbol: "square.and.arrow.down.badge.exclamationmark", tone: .warning))
        } else if !profile.hasUsageData && profile.error == nil {
            badges.append(.init(title: "No usage data", symbol: "waveform.path.ecg", tone: .info))
        }

        if !profile.warnings.isEmpty {
            badges.append(.init(title: "Attention", symbol: "exclamationmark.circle.fill", tone: .warning))
        }

        return badges
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ProfileFilter.allCases) { filter in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedFilter = filter
                        }
                        requestTopScroll()
                    } label: {
                        Text(filter.title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(selectedFilter == filter ? Color.white : palette.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: filter == .hasUsage ? 90 : 74)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        selectedFilter == filter
                                            ? LinearGradient(
                                                colors: [palette.accent, palette.accentSecondary],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            : LinearGradient(
                                                colors: [palette.subtleFill, palette.subtleFill.opacity(0.72)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(selectedFilter == filter ? palette.cardStroke.opacity(1.4) : palette.cardStroke, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(selectedFilter == filter ? 1.0 : 0.985)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.chipFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.chipStroke, lineWidth: 1)
                    )
            )

            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: selectedFilter)
    }

    private var filterBarHeader: some View {
        filterBar
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
            .background(
                LinearGradient(
                    colors: [palette.backgroundStart, palette.backgroundEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var filterCountBadge: some View {
        Text("\(filteredProfiles.count)")
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(palette.primaryText.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(palette.subtleFill)
                    .overlay(
                        Capsule()
                            .stroke(palette.cardStroke, lineWidth: 1)
                    )
            )
    }

    private var bulkActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedBulkProfiles.count) selected")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text("Favorite, export, or delete several saved profiles at once.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                ActionButton(
                    title: shouldRemoveFavoritesInBulk ? "Remove favorite" : "Add favorite",
                    symbol: shouldRemoveFavoritesInBulk ? "star.slash" : "star.fill"
                ) {
                    let selectedIDs = Set(selectedBulkProfiles.compactMap(\.id))
                    model.setFavoriteState(for: selectedIDs, isFavorite: !shouldRemoveFavoritesInBulk)
                }
                .disabled(selectedBulkProfiles.compactMap(\.id).isEmpty)

                ActionButton(title: "Export Selected", symbol: "square.and.arrow.up") {
                    Task {
                        let selectedIDs = selectedBulkProfiles.compactMap(\.id)
                        guard !selectedIDs.isEmpty,
                              let url = presentSavePanel(suggestedName: "codex-selected-profiles.json") else { return }
                        _ = await model.exportProfiles(
                            ids: selectedIDs,
                            to: url,
                            descriptor: "\(selectedIDs.count) selected profiles"
                        )
                    }
                }
                .disabled(selectedBulkProfiles.compactMap(\.id).isEmpty)

                ActionButton(title: "Delete Selected", symbol: "trash") {
                    presentBulkDelete()
                }
                .disabled(selectedBulkProfiles.filter(\.isSaved).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.cardStroke, lineWidth: 1)
                )
        )
    }
}

struct ProfileCard: View {
    let profile: ProfileStatus
    let showID: Bool
    let isFavorite: Bool
    let isCompact: Bool
    let sparklineValues: [Int]
    let healthBadges: [ProfileHealthBadgeDescriptor]
    let isSelected: Bool
    let isBulkMode: Bool
    let isBulkSelected: Bool
    let isSwitching: Bool
    let isSwitchDisabled: Bool
    let isClearingLabel: Bool
    let onSwitch: () -> Void
    let onToggleFavorite: () -> Void
    let onSelect: () -> Void
    let onEditLabel: () -> Void
    let onClearLabel: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onToggleBulkSelection: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 10 : 14) {
            HStack(alignment: .top, spacing: 14) {
                if isBulkMode {
                    Button(action: onToggleBulkSelection) {
                        Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isBulkSelected ? palette.accent : palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                Circle()
                    .fill(toneColor.opacity(0.22))
                    .frame(width: isCompact ? 34 : 40, height: isCompact ? 34 : 40)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                            .foregroundStyle(toneColor)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(profile.primaryText)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        statusChip
                        if let percent = profile.usageDisplayPercent {
                            Text("\(percent)%")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(toneColor)
                        }
                    }

                    if !profile.secondaryText.isEmpty {
                        Text(profile.secondaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }

                    if showID, let id = profile.id {
                        Text(id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(palette.tertiaryText)
                            .lineLimit(1)
                    }

                    Text(profile.statusLabel)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(isCompact ? 2 : 3)
                        .padding(.top, profile.secondaryText.isEmpty && profile.id == nil ? 2 : 0)

                    if !healthBadges.isEmpty {
                        HealthBadgesRow(
                            badges: Array(healthBadges.prefix(isCompact ? 2 : 3)),
                            palette: palette
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: isCompact ? 10 : 12) {
                    HStack(spacing: 10) {
                        if shouldShowSparkline {
                            SparklineView(values: sparklineValues, color: toneColor)
                                .frame(width: 54, height: 18)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(palette.subtleFill)
                                        .overlay(
                                            Capsule()
                                                .stroke(palette.cardStroke, lineWidth: 1)
                                        )
                                )
                        }

                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isFavorite ? palette.warning : palette.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove favorite" : "Add favorite")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    if isBulkMode {
                        Text(isBulkSelected ? "Selected" : "Select")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(isBulkSelected ? Color.white : palette.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isBulkSelected ? palette.accent : palette.subtleFill)
                            )
                    } else if profile.canSwitch {
                        Button {
                            onSwitch()
                        } label: {
                            HStack(spacing: 7) {
                                if isSwitching {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 13, height: 13)
                                } else {
                                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .frame(width: 13, height: 13)
                                }
                                Text(isSwitching ? "Switching" : "Switch")
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                            }
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 100)
                        }
                        .buttonStyle(SwitchButtonStyle(isActive: isSwitching))
                        .disabled(isSwitchDisabled)
                        .controlSize(.regular)
                    } else {
                        Text(secondaryStateLabel)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(palette.subtleFill, in: Capsule())
                    }

                    if !isBulkMode {
                        Menu {
                            if profile.isSaved {
                                Button(isFavorite ? "Remove favorite" : "Add favorite", systemImage: isFavorite ? "star.slash" : "star") {
                                    onToggleFavorite()
                                }
                                Button("Edit label", systemImage: "pencil") {
                                    onEditLabel()
                                }

                                if profile.label != nil {
                                    Button("Clear label", systemImage: "tag.slash") {
                                        onClearLabel()
                                    }
                                    .disabled(isClearingLabel)
                                }

                                Button("Export JSON", systemImage: "square.and.arrow.up") {
                                    onExport()
                                }

                                Divider()

                                Button("Delete profile", systemImage: "trash", role: .destructive) {
                                    onDelete()
                                }
                            } else {
                                Text("Save current session first")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 16, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(palette.primaryText.opacity(0.92))
                            .padding(.horizontal, 2)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .frame(minWidth: 112, alignment: .trailing)
            }

            if !isCompact, let usage = profile.usage, usage.state == "ok", let bucket = profile.primaryUsageBucket {
                VStack(spacing: 8) {
                    UsageMeterRow(title: bucket.label, windowTitle: "5h", window: bucket.fiveHour)
                    UsageMeterRow(title: bucket.label, windowTitle: "Weekly", window: bucket.weekly)
                }
            }
        }
        .padding(isCompact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(cardStrokeColor, lineWidth: isSwitching || isSelected ? 1.5 : 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onSelect)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isSwitching)
    }

    private var toneColor: Color {
        switch profile.tone {
        case .good:
            Color(red: 0.16, green: 0.82, blue: 0.47)
        case .warning:
            Color(red: 0.98, green: 0.74, blue: 0.23)
        case .error:
            Color(red: 0.97, green: 0.34, blue: 0.39)
        }
    }

    private var iconName: String {
        if profile.isCurrent {
            return "checkmark.seal.fill"
        }
        if profile.error != nil {
            return "exclamationmark.triangle.fill"
        }
        return "person.crop.circle.fill"
    }

    private var statusChip: some View {
        Text(profile.isApiKey ? "API Key" : (profile.plan?.capitalized ?? "Codex"))
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .foregroundStyle(toneColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(toneColor.opacity(0.14), in: Capsule())
    }

    private var cardStrokeColor: Color {
        if isSwitching {
            return palette.success.opacity(0.78)
        }
        if isBulkSelected {
            return palette.accent.opacity(0.95)
        }
        if isSelected {
            return palette.accent.opacity(0.9)
        }
        return toneColor.opacity(0.35)
    }

    private var shouldShowSparkline: Bool {
        sparklineValues.count >= 3
    }

    private var secondaryStateLabel: String {
        if profile.isCurrent {
            return "Active"
        }
        if profile.error != nil {
            return "Needs repair"
        }
        return "Saved"
    }
}

enum ProfileHealthBadgeTone {
    case info
    case success
    case warning
    case error
}

struct ProfileHealthBadgeDescriptor: Identifiable, Hashable {
    let title: String
    let symbol: String
    let tone: ProfileHealthBadgeTone

    var id: String { "\(title)-\(symbol)" }
}

struct HealthBadgesRow: View {
    let badges: [ProfileHealthBadgeDescriptor]
    let palette: PanelPalette

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(badges) { badge in
                HStack(spacing: 5) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 10, weight: .bold))
                    Text(badge.title)
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                }
                .foregroundStyle(foregroundColor(for: badge.tone))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(backgroundColor(for: badge.tone), in: Capsule())
            }
        }
    }

    private func foregroundColor(for tone: ProfileHealthBadgeTone) -> Color {
        switch tone {
        case .info:
            palette.secondaryText
        case .success:
            palette.success
        case .warning:
            palette.warning
        case .error:
            palette.danger
        }
    }

    private func backgroundColor(for tone: ProfileHealthBadgeTone) -> Color {
        switch tone {
        case .info:
            palette.subtleFill
        case .success:
            palette.success.opacity(0.12)
        case .warning:
            palette.warning.opacity(0.14)
        case .error:
            palette.danger.opacity(0.14)
        }
    }
}

struct ActiveProfileSpotlightCard: View {
    let profile: ProfileStatus
    let showID: Bool
    let isFavorite: Bool
    let sparklineValues: [Int]
    let healthBadges: [ProfileHealthBadgeDescriptor]
    let recommendation: ProfileSwitchRecommendation?
    let isRestartingCodex: Bool
    let onToggleFavorite: () -> Void
    let onReopen: () -> Void
    let onSwitchRecommended: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Active Session")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(palette.accent)
                    HStack(spacing: 8) {
                        Text(profile.primaryText)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        if let percent = profile.usageDisplayPercent {
                            Text("\(percent)% left")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(palette.success)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(palette.success.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(profile.statusLabel)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    if !healthBadges.isEmpty {
                        HealthBadgesRow(badges: healthBadges, palette: palette)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if sparklineValues.count >= 3 {
                        SparklineView(values: sparklineValues, color: palette.success)
                            .frame(width: 62, height: 20)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(palette.subtleFill)
                                    .overlay(
                                        Capsule()
                                            .stroke(palette.cardStroke, lineWidth: 1)
                                    )
                            )
                    }

                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isFavorite ? palette.warning : palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !profile.secondaryText.isEmpty || (showID && profile.id != nil) {
                VStack(alignment: .leading, spacing: 4) {
                    if !profile.secondaryText.isEmpty {
                        Text(profile.secondaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                    }

                    if showID, let id = profile.id {
                        Text(id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
            }

            if let usage = profile.usage, usage.state == "ok", let bucket = profile.primaryUsageBucket {
                VStack(spacing: 8) {
                    UsageMeterRow(title: bucket.label, windowTitle: "5h", window: bucket.fiveHour)
                    UsageMeterRow(title: bucket.label, windowTitle: "Weekly", window: bucket.weekly)
                }
            }

            if let recommendation {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smart switch recommendation")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(palette.accent)
                        Text("\(recommendation.profileName) has \(recommendation.usagePercent)% remaining.")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(recommendation.reason)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }

                    Spacer()

                    Button {
                        onSwitchRecommended()
                    } label: {
                        Text("Switch to backup")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(palette.subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.cardStroke, lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 10) {
                Button(action: onReopen) {
                    HStack(spacing: 8) {
                        if isRestartingCodex {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                        }
                        Text(isRestartingCodex ? "Reopening…" : "Reopen Codex")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SwitchButtonStyle(isActive: isRestartingCodex))
                .disabled(isRestartingCodex)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.cardFill, palette.subtleFill.opacity(1.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(palette.accent.opacity(0.45), lineWidth: 1.2)
                )
        )
    }
}

struct SearchField: View {
    @Binding var text: String
    let palette: PanelPalette
    var focusBinding: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryText)
            searchTextField
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(palette.cardStroke, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var searchTextField: some View {
        if let focusBinding {
            TextField("Search label, email, plan…", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.primaryText)
                .focused(focusBinding)
        } else {
            TextField("Search label, email, plan…", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.primaryText)
        }
    }
}

struct AggregateUsageCard: View {
    let summary: AggregateUsageSummary
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aggregate Usage")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text("\(summary.trackedProfilesCount) profiles tracked • \(summary.favoritesCount) favorites")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                if summary.lowProfilesCount > 0 {
                    Text("\(summary.lowProfilesCount) low")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.warning.opacity(0.14), in: Capsule())
                }
            }

            HStack(spacing: 10) {
                aggregateMetric(title: "5h total", value: "\(summary.totalFiveHourPercent)%", tint: palette.accent)
                aggregateMetric(title: "Weekly total", value: "\(summary.totalWeeklyPercent)%", tint: palette.success)
                aggregateMetric(title: "Avg 5h", value: "\(summary.averageFiveHourPercent)%", tint: palette.secondaryText)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.cardStroke, lineWidth: 1)
                )
        )
    }

    private func aggregateMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.subtleFill)
        )
    }
}

struct SparklineView: View {
    let values: [Int]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        if values.count == 1 {
            return [CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2)]
        }

        let clamped = values.map { CGFloat(max(0, min(100, $0))) }
        let stepX = size.width / CGFloat(max(clamped.count - 1, 1))
        return clamped.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * stepX,
                y: size.height - (value / 100) * size.height
            )
        }
    }
}

struct QuickSwitchOverlay: View {
    @Binding var query: String
    let profiles: [ProfileStatus]
    @Binding var selectedIndex: Int
    let onChoose: (ProfileStatus) -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Switch")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                        Text("Type a label, email, or plan. Press Enter to switch.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                }

                SearchField(text: $query, palette: palette, focusBinding: $isSearchFocused)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(profiles.enumerated()), id: \.element.stableID) { index, profile in
                            Button {
                                onChoose(profile)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: profile.isCurrent ? "checkmark.circle.fill" : "person.crop.circle")
                                        .foregroundStyle(profile.isCurrent ? palette.success : palette.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.primaryText)
                                            .font(.system(.headline, design: .rounded, weight: .semibold))
                                        if !profile.secondaryText.isEmpty {
                                            Text(profile.secondaryText)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(palette.secondaryText)
                                        }
                                    }
                                    Spacer()
                                    if let percent = profile.usageDisplayPercent {
                                        Text("\(percent)%")
                                            .font(.system(.caption, design: .monospaced, weight: .bold))
                                            .foregroundStyle(profile.isLowUsage(threshold: 10) ? palette.warning : palette.primaryText)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(index == selectedIndex ? palette.subtleFill.opacity(1.4) : palette.subtleFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(index == selectedIndex ? palette.accent.opacity(0.9) : palette.cardStroke, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)

                if profiles.isEmpty {
                    Text("No profiles match this search.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .frame(width: 360)
        }
        .task {
            isSearchFocused = true
        }
    }
}

struct SaveProfileOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let onClose: () -> Void
    @State private var label = ""
    @State private var isSaving = false

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save Current Session")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text("Optionally add a label so the profile is easier to recognize in the status bar list.")
                    .foregroundStyle(.secondary)

                TextField("work, personal, staging…", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onClose()
                    }
                    .disabled(isSaving)
                    Button(action: {
                        guard !isSaving else { return }
                        isSaving = true
                        Task {
                            let didSave = await model.saveCurrent(label: label)
                            await MainActor.run {
                                isSaving = false
                                if didSave {
                                    onClose()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isSaving ? "Saving…" : "Save")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
                .animation(.easeInOut(duration: 0.18), value: isSaving)
            }
            .frame(width: 344)
        }
    }
}

struct EditLabelOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let profile: ProfileStatus
    let onClose: () -> Void

    @State private var label: String
    @State private var isSaving = false

    init(model: CodexProfilesViewModel, profile: ProfileStatus, onClose: @escaping () -> Void) {
        self.model = model
        self.profile = profile
        self.onClose = onClose
        _label = State(initialValue: profile.label ?? "")
    }

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Label")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text(profile.primaryText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onClose()
                    }
                    .disabled(isSaving)
                    Button(action: {
                        guard !isSaving else { return }
                        isSaving = true
                        Task {
                            let didSave = await model.updateLabel(for: profile, newLabel: label)
                            await MainActor.run {
                                isSaving = false
                                if didSave {
                                    onClose()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isSaving ? "Saving…" : "Save")
                        }
                        .contentTransition(.opacity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
                .animation(.easeInOut(duration: 0.18), value: isSaving)
            }
            .frame(width: 336)
        }
    }
}

struct DeleteProfileOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let profile: ProfileStatus
    let onClose: () -> Void
    @State private var isDeleting = false

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete saved profile?")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text(profile.primaryText)
                    .font(.system(.headline, design: .rounded, weight: .semibold))

                if !profile.secondaryText.isEmpty {
                    Text(profile.secondaryText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("This will permanently remove the saved profile from Codex Profiles.")
                    .foregroundStyle(.secondary)

                Text("This action cannot be undone.")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onClose()
                    }
                    .disabled(isDeleting)
                    Button(role: .destructive, action: {
                        guard !isDeleting else { return }
                        isDeleting = true
                        Task {
                            let didDelete = await model.deleteProfile(profile)
                            await MainActor.run {
                                isDeleting = false
                                if didDelete {
                                    onClose()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isDeleting ? "Deleting…" : "Delete")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(.red)
                    .disabled(isDeleting)
                }
                .animation(.easeInOut(duration: 0.18), value: isDeleting)
            }
            .frame(width: 336)
        }
    }
}

struct DeleteProfilesOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let profiles: [ProfileStatus]
    let onClose: () -> Void
    @State private var isDeleting = false

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete selected profiles?")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text("\(profiles.count) saved profiles will be removed from Codex Profiles.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(profiles.prefix(4)), id: \.stableID) { profile in
                        Text("• \(profile.primaryText)")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if profiles.count > 4 {
                        Text("• and \(profiles.count - 4) more")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("This action cannot be undone.")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onClose()
                    }
                    .disabled(isDeleting)
                    Button(role: .destructive, action: {
                        guard !isDeleting else { return }
                        isDeleting = true
                        Task {
                            let didDelete = await model.deleteProfiles(profiles)
                            await MainActor.run {
                                isDeleting = false
                                if didDelete {
                                    onClose()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isDeleting ? "Deleting…" : "Delete selected")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(.red)
                    .disabled(isDeleting)
                }
            }
            .frame(width: 360)
        }
    }
}

struct UnsavedSwitchOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let profile: ProfileStatus
    let onClose: () -> Void
    @State private var pendingMode: SwitchMode?

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Current session is unsaved")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text("Switching to \(profile.primaryText) would overwrite the current `auth.json` unless you save first.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Cancel") {
                        onClose()
                    }
                    .disabled(pendingMode != nil)
                    Spacer()
                    Button(action: {
                        triggerSwitch(mode: .force)
                    }) {
                        HStack(spacing: 8) {
                            if pendingMode == .force {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(pendingMode == .force ? "Switching…" : "Switch without saving")
                        }
                    }
                    .disabled(pendingMode != nil)
                    Button(action: {
                        triggerSwitch(mode: .saveThenSwitch)
                    }) {
                        HStack(spacing: 8) {
                            if pendingMode == .saveThenSwitch {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(pendingMode == .saveThenSwitch ? "Saving…" : "Save current, then switch")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pendingMode != nil)
                }
                .animation(.easeInOut(duration: 0.18), value: pendingMode)
            }
            .frame(width: 356)
        }
    }

    private func triggerSwitch(mode: SwitchMode) {
        guard pendingMode == nil else { return }
        pendingMode = mode
        Task {
            let didSwitch = await model.switchToProfile(profile, mode: mode)
            await MainActor.run {
                pendingMode = nil
                if didSwitch {
                    onClose()
                }
            }
        }
    }
}

struct CodexRelaunchOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let prompt: CodexRelaunchPrompt
    let onClose: () -> Void

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reopen Codex now?")
                    .font(.system(.title3, design: .rounded, weight: .bold))

                Text("The profile has been switched to \(prompt.profileName). Reopening Codex will make the new profile available right away.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Later") {
                        onClose()
                    }
                    .disabled(model.isRestartingCodex)

                    Spacer()

                    Button(action: {
                        Task {
                            let didRestart = await model.restartCodex()
                            await MainActor.run {
                                if didRestart {
                                    onClose()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if model.isRestartingCodex {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(model.isRestartingCodex ? "Reopening…" : "Reopen Codex")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRestartingCodex)
                }
                .animation(.easeInOut(duration: 0.18), value: model.isRestartingCodex)
            }
            .frame(width: 356)
        }
    }
}

struct OverlayCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct DoctorOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let onClose: () -> Void

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Doctor")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Spacer()
                    if model.isDoctorLoading {
                        ProgressView()
                    }
                }

                if let report = model.doctorReport {
                    DoctorSummaryView(summary: report.summary)

                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(report.checks) { check in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(check.level.uppercased())
                                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                                        .foregroundStyle(levelColor(check.level))
                                        .frame(width: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(check.name)
                                            .font(.system(.callout, weight: .semibold))
                                        Text(check.detail)
                                            .font(.system(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    if let repairs = report.repairs, !repairs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Repairs")
                                .font(.system(.headline, weight: .semibold))
                            ForEach(repairs, id: \.self) { repair in
                                Text("• \(repair)")
                                    .font(.system(.caption))
                            }
                        }
                    }
                } else if model.isDoctorLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Running checks…")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    Spacer()
                    EmptyStateView(
                        title: "No doctor report yet",
                        message: "Run diagnostics to verify auth, profiles storage, permissions, and saved profile health."
                    )
                    Spacer()
                }

                HStack {
                    Button("Repair Safe Issues") {
                        Task { await model.loadDoctorReport(fix: true) }
                    }
                    .disabled(model.isDoctorLoading)
                    Spacer()
                    Button("Close") {
                        onClose()
                    }
                    .disabled(model.isDoctorLoading)
                }
            }
        }
        .frame(maxWidth: 372, maxHeight: 560)
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ok":
            .green
        case "warn":
            .orange
        case "error":
            .red
        default:
            .secondary
        }
    }
}

struct NotificationInboxOverlay: View {
    @ObservedObject var model: CodexProfilesViewModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notification Inbox")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                        Text("Important alerts, auto-switch events, and recommended follow-up actions.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                }

                if model.notificationInboxItems.isEmpty {
                    EmptyStateView(
                        title: "No notifications yet",
                        message: "Low-usage alerts, reset reminders, and auto-switch events will appear here."
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    HStack(spacing: 10) {
                        Button("Mark all read") {
                            model.markAllInboxItemsRead()
                        }
                        .disabled(model.unreadInboxCount == 0)

                        Button("Clear inbox") {
                            model.clearNotificationInbox()
                        }

                        Spacer()

                        Text("\(model.notificationInboxItems.count) items")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                    }

                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.notificationInboxItems) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Circle()
                                            .fill(toneColor(for: item.tone).opacity(0.18))
                                            .frame(width: 30, height: 30)
                                            .overlay(
                                                Image(systemName: toneSymbol(for: item.tone))
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(toneColor(for: item.tone))
                                            )

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(item.title)
                                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                                    .foregroundStyle(palette.primaryText)
                                                if item.isUnread {
                                                    Circle()
                                                        .fill(palette.accent)
                                                        .frame(width: 8, height: 8)
                                                }
                                                Spacer()
                                                Text(item.createdAt.formatted(.relative(presentation: .named)))
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(palette.tertiaryText)
                                            }

                                            Text(item.body)
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundStyle(palette.secondaryText)
                                        }
                                    }

                                    HStack(spacing: 10) {
                                        if let actionLabel = item.actionLabel, item.actionKind != nil {
                                            Button(actionLabel) {
                                                Task {
                                                    _ = await model.performInboxAction(for: item)
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }

                                        if item.isUnread {
                                            Button("Mark read") {
                                                model.markInboxItemRead(item)
                                            }
                                        }

                                        Spacer()
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(palette.subtleFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(item.isUnread ? palette.accent.opacity(0.35) : palette.cardStroke, lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
            }
        }
        .frame(maxWidth: 420, maxHeight: 560)
    }

    private func toneColor(for tone: NotificationInboxTone) -> Color {
        switch tone {
        case .info:
            palette.accent
        case .success:
            palette.success
        case .warning:
            palette.warning
        case .error:
            palette.danger
        }
    }

    private func toneSymbol(for tone: NotificationInboxTone) -> String {
        switch tone {
        case .info:
            "bell.fill"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                maxLineWidth = max(maxLineWidth, currentX - spacing)
                currentX = 0
                currentY += currentLineHeight + lineSpacing
                currentLineHeight = 0
            }

            currentLineHeight = max(currentLineHeight, size.height)
            currentX += size.width + spacing
        }

        maxLineWidth = max(maxLineWidth, max(0, currentX - spacing))
        return CGSize(width: maxLineWidth, height: currentY + currentLineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentLineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += currentLineHeight + lineSpacing
                currentLineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            currentX += size.width + spacing
            currentLineHeight = max(currentLineHeight, size.height)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: CodexProfilesViewModel
    let resolvedColorScheme: ColorScheme
    var embedded = false
    var onClose: (() -> Void)?
    @AppStorage(Preferences.showIDsKey) private var showIDs = false
    @AppStorage(Preferences.autoRefreshKey) private var autoRefreshEnabled = true
    @AppStorage(Preferences.promptReopenCodexKey) private var promptReopenCodex = true
    @AppStorage(Preferences.panelThemeKey) private var panelTheme = PanelTheme.system.rawValue
    @AppStorage(Preferences.compactModeKey) private var compactMode = false
    @AppStorage(Preferences.groupingKey) private var grouping = ProfileGrouping.none.rawValue
    @AppStorage(Preferences.notificationsEnabledKey) private var notificationsEnabled = true
    @AppStorage(Preferences.autoSwitchOnDepletionKey) private var autoSwitchOnDepletion = false
    @AppStorage(Preferences.usageWarningThresholdKey) private var usageWarningThreshold = 10
    @AppStorage(Preferences.accentRedKey) private var accentRed = 0.15
    @AppStorage(Preferences.accentGreenKey) private var accentGreen = 0.44
    @AppStorage(Preferences.accentBlueKey) private var accentBlue = 0.95

    private var palette: PanelPalette {
        PanelPalette.resolve(for: resolvedColorScheme, accent: Color(red: accentRed, green: accentGreen, blue: accentBlue))
    }

    private var currentAppVersionText: String {
        let bundle = Bundle.main
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let shortVersion, !shortVersion.isEmpty, let buildVersion, !buildVersion.isEmpty, buildVersion != shortVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        if let shortVersion, !shortVersion.isEmpty {
            return shortVersion
        }
        if let buildVersion, !buildVersion.isEmpty {
            return buildVersion
        }
        return "Development build"
    }

    private var updateStatusText: String {
        if let release = model.availableAppUpdate {
            return "Update available: \(release.version)"
        }
        if model.isInstallingUpdate {
            return "Installing update…"
        }
        if model.isCheckingForUpdates {
            return "Checking for updates…"
        }
        return "No update check running"
    }

    private var accentColorBinding: Binding<CGColor> {
        Binding(
            get: { AccentTheme.cgColor() },
            set: { AccentTheme.save($0) }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundStart, palette.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsHeader
                    startupCard
                    storageCard
                    displayCard
                    behaviorCard
                    updatesCard
                }
                .padding(24)
            }
        }
        .environment(\.colorScheme, resolvedColorScheme)
    }

    private var settingsHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CodexProfilesBar Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
            }
            Spacer()
            if embedded, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }
        }
    }

    private var startupCard: some View {
        SettingsCard(
            eyebrow: "Startup",
            title: "Launch At Login",
            detail: nil
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Toggle(
                        isOn: Binding(
                            get: { model.launchAtLoginState.isEnabled },
                            set: { enabled in
                                Task { await model.setLaunchAtLogin(enabled) }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open automatically after login")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                            Text(model.launchAtLoginState.detail)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!model.launchAtLoginState.canToggle || model.isUpdatingLaunchAtLogin)

                    Spacer()

                    StartupStatusBadge(state: model.launchAtLoginState)
                }

                if model.isUpdatingLaunchAtLogin {
                    ProgressView("Updating login item…")
                        .controlSize(.small)
                }
            }
        }
    }

    private var storageCard: some View {
        SettingsCard(
            eyebrow: "Storage",
            title: "Codex Storage",
            detail: "Uses your local Codex session directly from ~/.codex."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let detected = model.detectedStorage {
                    LabeledSettingRow(
                        label: "Codex home",
                        value: detected.url.path,
                        isMonospaced: true
                    )
                }

                LabeledSettingRow(
                    label: "Detected Codex",
                    value: model.detectedCodexVersion.summary,
                    isMonospaced: true
                )

                Text("If profiles do not appear, sign in once with `codex login` so ~/.codex/auth.json is available.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var displayCard: some View {
        SettingsCard(
            eyebrow: "Display",
            title: "List Preferences",
            detail: nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $showIDs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show profile IDs in the list")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                    }
                }
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Panel theme")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Picker("Panel theme", selection: $panelTheme) {
                        ForEach(PanelTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent color")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    HStack(spacing: 12) {
                        ColorPicker("Accent", selection: accentColorBinding, supportsOpacity: false)
                            .labelsHidden()
                        Button("Reset Default") {
                            AccentTheme.reset()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Grouping")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Picker("Grouping", selection: $grouping) {
                        ForEach(ProfileGrouping.allCases) { group in
                            Text(group.title).tag(group.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle(isOn: $compactMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Compact mode")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("Dense list layout that hides usage bars and keeps sparkline + key status only.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                Toggle(
                    isOn: Binding(
                        get: { autoRefreshEnabled },
                        set: { enabled in
                            autoRefreshEnabled = enabled
                            model.setAutoRefreshEnabled(enabled)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh usage automatically every minute")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("Keeps usage and status fresh while the app is running.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $promptReopenCodex) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask to reopen Codex after switching")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("Shows a prompt after profile switches so the new session can be used right away.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var behaviorCard: some View {
        SettingsCard(
            eyebrow: "Behavior",
            title: "Warnings & Recovery",
            detail: nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local notifications for low usage")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("Uses macOS notifications when profiles drop below the configured threshold or are close to reset.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Low-usage threshold: \(usageWarningThreshold)%")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Slider(value: Binding(
                        get: { Double(usageWarningThreshold) },
                        set: { usageWarningThreshold = Int($0.rounded()) }
                    ), in: 5...30, step: 1)
                }

                Toggle(isOn: $autoSwitchOnDepletion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-switch when current profile is depleted")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("Automatically moves to the saved profile with the highest remaining usage.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var updatesCard: some View {
        SettingsCard(
            eyebrow: "Software",
            title: "Updates",
            detail: "Keep Codex Profiles Bar current with the latest packaged release."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledSettingRow(
                    label: "Current version",
                    value: currentAppVersionText,
                    isMonospaced: true
                )

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updateStatusText)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(
                            model.availableAppUpdate == nil
                                ? "Checks GitHub Releases and shows release notes before installing."
                                : "Open the updater dialog to review notes and install the new version."
                        )
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                    }

                    Spacer()

                    Button {
                        if model.availableAppUpdate != nil {
                            model.showAvailableUpdateDetails()
                        } else {
                            Task { await model.checkForUpdates(userInitiated: true) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isCheckingForUpdates || model.isInstallingUpdate {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.availableAppUpdate == nil ? "Check for Update" : "View Update")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(palette.accent)

                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.cardFill)
                .shadow(color: palette.shadow.opacity(0.45), radius: 16, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.cardStroke, lineWidth: 1)
        )
    }
}

struct StartupStatusBadge: View {
    let state: LaunchAtLoginState

    var body: some View {
        Text(state.title)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch state.kind {
        case .enabled:
            Color(red: 0.10, green: 0.54, blue: 0.29)
        case .requiresApproval:
            Color(red: 0.77, green: 0.45, blue: 0.08)
        case .disabled:
            Color(red: 0.28, green: 0.35, blue: 0.49)
        case .unavailable:
            Color(red: 0.63, green: 0.26, blue: 0.26)
        }
    }

    private var background: Color {
        switch state.kind {
        case .enabled:
            Color.green.opacity(0.14)
        case .requiresApproval:
            Color.orange.opacity(0.16)
        case .disabled:
            Color.gray.opacity(0.15)
        case .unavailable:
            Color.red.opacity(0.12)
        }
    }
}

struct LabeledSettingRow: View {
    let label: String
    let value: String
    let isMonospaced: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(palette.secondaryText)

            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .system(.caption, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .textSelection(.enabled)
        }
    }
}

struct CommandSnippet: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color(red: 0.17, green: 0.23, blue: 0.34))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.93, green: 0.95, blue: 0.99))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.84, green: 0.88, blue: 0.95), lineWidth: 1)
            )
    }
}

struct UsageMeterRow: View {
    let title: String
    let windowTitle: String
    let window: UsageWindow?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        let percent = max(0, min(100, window?.leftPercent ?? 0))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(windowTitle)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if let window {
                    Text("\(percent)% left · resets \(window.relativeResetText())")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                } else {
                    Text("No \(title.lowercased()) data")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.subtleFill)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    palette.success.opacity(0.88),
                                    palette.accentSecondary.opacity(0.92),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(height: 7)
        }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, minHeight: 18)
        }
        .buttonStyle(ActionPillButtonStyle())
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(palette.tertiaryText)
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text(message)
                .font(.system(.caption, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: 300)
        }
    }
}

struct BannerView: View {
    let message: BannerMessage
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(message.body)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(palette.subtleFill, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close notification")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accentColor.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private var accentColor: Color {
        switch message.tone {
        case .info:
            .blue
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private var symbolName: String {
        switch message.tone {
        case .info:
            "info.circle.fill"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.circle.fill"
        }
    }
}

struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRefreshing ? palette.subtleFill.opacity(1.4) : palette.iconFill)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.success)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

struct RefreshActivityBadge: View {
    let isRefreshing: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette {
        PanelPalette.resolve(for: colorScheme)
    }

    var body: some View {
        if isRefreshing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.success)
                Text("Refreshing")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(palette.success)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.subtleFill, in: Capsule())
            .transition(.opacity.combined(with: .scale))
        }
    }
}

struct DoctorSummaryView: View {
    let summary: DoctorSummary

    var body: some View {
        HStack(spacing: 10) {
            summaryCard(title: "OK", value: summary.ok, color: .green)
            summaryCard(title: "Warn", value: summary.warn, color: .orange)
            summaryCard(title: "Error", value: summary.error, color: .red)
            summaryCard(title: "Info", value: summary.info, color: .blue)
        }
    }

    private func summaryCard(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let palette = PanelPalette.resolve(for: colorScheme)
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .foregroundStyle(palette.primaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? palette.subtleFill.opacity(1.4) : palette.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.cardStroke, lineWidth: 1)
            )
    }
}

struct SwitchButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(red: 0.05, green: 0.12, blue: 0.12))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.27, green: 0.98, blue: 0.69),
                                Color(red: 0.18, green: 0.83, blue: 0.55),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(configuration.isPressed ? 0.86 : 1.0)
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isActive ? 0.55 : 0), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : (isActive ? 1.03 : 1.0))
            .shadow(color: Color(red: 0.27, green: 0.98, blue: 0.69).opacity(isActive ? 0.45 : 0), radius: 12, x: 0, y: 6)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isActive)
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let palette = PanelPalette.resolve(for: colorScheme)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(configuration.isPressed ? palette.subtleFill.opacity(1.4) : palette.iconFill)
            )
    }
}

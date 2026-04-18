import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let menuBarRootCoordinateSpace = "menu-bar-root"

struct MenuBarRootView: View {
    @ObservedObject var model: CodexProfilesViewModel
    @AppStorage(Preferences.showIDsKey) private var showIDs = false
    @Environment(\.openSettings) private var openSettings

    @State private var showImportPicker = false
    @State private var showSaveSheet = false
    @State private var showDoctorSheet = false
    @State private var selectedFilter: ProfileFilter = .all
    @State private var labelEditorTarget: ProfileStatus?
    @State private var deleteTarget: ProfileStatus?
    @State private var switchTarget: ProfileStatus?
    @State private var activeActionsMenuProfileID: String?
    @State private var actionsMenuButtonFrames: [String: CGRect] = [:]
    @State private var isImporting = false
    @State private var isExportingAll = false
    @State private var clearingLabelProfileID: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.16),
                    Color(red: 0.04, green: 0.06, blue: 0.11),
                ],
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

            if let profile = activeActionsMenuProfile,
               let buttonFrame = actionsMenuButtonFrames[profile.stableID],
               activeOverlayKind == nil
            {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture {
                                closeActionsMenu()
                            }

                        ProfileActionsMenu(
                            profile: profile,
                            isClearingLabel: clearingLabelProfileID == profile.stableID,
                            onEditLabel: {
                                labelEditorTarget = profile
                                closeActionsMenu()
                            },
                            onClearLabel: {
                                guard clearingLabelProfileID == nil else { return }
                                clearingLabelProfileID = profile.stableID
                                Task {
                                    _ = await model.clearLabel(for: profile)
                                    await MainActor.run {
                                        clearingLabelProfileID = nil
                                        closeActionsMenu()
                                    }
                                }
                            },
                            onExport: {
                                Task {
                                    guard let id = profile.id else { return }
                                    let suggestedName = profile.label ?? profile.id ?? "codex-profile"
                                    if let url = presentSavePanel(suggestedName: "\(suggestedName).json") {
                                        await model.exportProfiles(ids: [id], to: url, descriptor: profile.primaryText)
                                    }
                                }
                                closeActionsMenu()
                            },
                            onDelete: {
                                deleteTarget = profile
                                closeActionsMenu()
                            }
                        )
                        .padding(.leading, clampedActionsMenuX(in: geometry.size, buttonFrame: buttonFrame))
                        .padding(.top, actionsMenuY(in: geometry.size, buttonFrame: buttonFrame, profile: profile))
                        .onTapGesture { }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }

            if activeOverlayKind != nil {
                Color.black.opacity(0.42)
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
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: model.banner?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showDoctorSheet)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showSaveSheet)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: labelEditorTarget?.stableID)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: deleteTarget?.stableID)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: switchTarget?.stableID)
        .frame(width: 460, height: 640)
        .coordinateSpace(name: menuBarRootCoordinateSpace)
        .onPreferenceChange(ActionsMenuButtonFramePreferenceKey.self) { frames in
            actionsMenuButtonFrames = frames
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
        if showSaveSheet { return "save" }
        if labelEditorTarget != nil { return "label" }
        if deleteTarget != nil { return "delete" }
        if switchTarget != nil { return "switch" }
        return nil
    }

    private func dismissActiveOverlay() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            if switchTarget != nil {
                switchTarget = nil
            } else if deleteTarget != nil {
                deleteTarget = nil
            } else if labelEditorTarget != nil {
                labelEditorTarget = nil
            } else if showSaveSheet {
                showSaveSheet = false
            } else if showDoctorSheet {
                showDoctorSheet = false
            }
        }
    }

    private func closeActionsMenu() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            activeActionsMenuProfileID = nil
        }
    }

    private func clampedActionsMenuX(in size: CGSize, buttonFrame: CGRect) -> CGFloat {
        min(
            max(12, buttonFrame.maxX - ProfileActionsMenu.menuWidth),
            max(12, size.width - ProfileActionsMenu.menuWidth - 12)
        )
    }

    private func actionsMenuY(in size: CGSize, buttonFrame: CGRect, profile: ProfileStatus) -> CGFloat {
        let preferredBelowY = buttonFrame.maxY + 10
        let menuHeight = ProfileActionsMenu.estimatedHeight(for: profile)
        let bottomPadding: CGFloat = 12

        if preferredBelowY + menuHeight <= size.height - bottomPadding {
            return preferredBelowY
        }

        return max(12, buttonFrame.minY - menuHeight - 10)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Codex Profiles Bar")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    RefreshActivityBadge(isRefreshing: model.isRefreshingProfiles)
                }

                if let storage = model.detectedStorage {
                    Text("Managing profiles directly in \(storage.url.path)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(2)
                } else {
                    Text("Managing profiles directly in your Codex home.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(2)
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
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.profiles.isEmpty {
            Spacer()
            ProgressView("Loading profiles…")
                .tint(.white)
                .foregroundStyle(.white)
            Spacer()
        } else if model.profiles.isEmpty {
            Spacer()
            EmptyStateView(
                title: "No profiles yet",
                message: "Save the current auth first, then the menu bar will show every saved profile with its status and a one-click switch button."
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let lastRefresh = model.lastRefresh {
                            HStack {
                                Text(model.isRefreshingProfiles ? "Refreshing profiles…" : "Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(model.isRefreshingProfiles ? Color(red: 0.43, green: 0.96, blue: 0.76) : Color.white.opacity(0.6))
                                    .contentTransition(.opacity)
                                Spacer()
                            }
                        } else if model.isRefreshingProfiles {
                            HStack {
                                Text("Refreshing profiles…")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.43, green: 0.96, blue: 0.76))
                                Spacer()
                            }
                        }

                        if filteredProfiles.isEmpty {
                            EmptyStateView(
                                title: "No profiles match this filter",
                                message: "Try switching back to All, or save / refresh profiles that still have remaining usage."
                            )
                            .padding(.top, 30)
                        } else {
                            ForEach(filteredProfiles, id: \.stableID) { profile in
                                ProfileCard(
                                    profile: profile,
                                    showID: showIDs,
                                    isSwitching: model.switchingProfileID == profile.id,
                                    isSwitchDisabled: model.switchingProfileID != nil,
                                    isActionsMenuOpen: activeActionsMenuProfileID == profile.stableID,
                                    onSwitch: {
                                        if model.hasUnsavedCurrentProfile {
                                            switchTarget = profile
                                        } else {
                                            Task { await model.switchToProfile(profile, mode: .standard) }
                                        }
                                    },
                                    onEditLabel: {
                                        labelEditorTarget = profile
                                    },
                                    onClearLabel: {
                                        Task { await model.clearLabel(for: profile) }
                                    },
                                    onExport: {
                                        Task {
                                            guard let id = profile.id else { return }
                                            let suggestedName = profile.label ?? profile.id ?? "codex-profile"
                                            if let url = presentSavePanel(suggestedName: "\(suggestedName).json") {
                                                await model.exportProfiles(ids: [id], to: url, descriptor: profile.primaryText)
                                            }
                                        }
                                    },
                                    onDelete: {
                                        deleteTarget = profile
                                    },
                                    onToggleActionsMenu: {
                                        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                            if activeActionsMenuProfileID == profile.stableID {
                                                activeActionsMenuProfileID = nil
                                            } else {
                                                activeActionsMenuProfileID = profile.stableID
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    } header: {
                        filterBarHeader
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
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

    private var filteredProfiles: [ProfileStatus] {
        switch selectedFilter {
        case .all:
            model.profiles
        case .hasUsage:
            model.profiles.filter(\.hasRemainingUsage)
        }
    }

    private var activeActionsMenuProfile: ProfileStatus? {
        guard let activeActionsMenuProfileID else { return nil }
        return model.profiles.first(where: { $0.stableID == activeActionsMenuProfileID })
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ProfileFilter.allCases) { filter in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(selectedFilter == filter ? .white : Color.white.opacity(0.74))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: filter == .hasUsage ? 90 : 58)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        selectedFilter == filter
                                            ? LinearGradient(
                                                colors: [
                                                    Color(red: 0.15, green: 0.52, blue: 0.99),
                                                    Color(red: 0.08, green: 0.42, blue: 0.90),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            : LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.06),
                                                    Color.white.opacity(0.03),
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        selectedFilter == filter
                                            ? Color.white.opacity(0.16)
                                            : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(selectedFilter == filter ? 1.0 : 0.985)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )

            Text("\(filteredProfiles.count)")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: selectedFilter)
    }

    private var filterBarHeader: some View {
        filterBar
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.10, blue: 0.16),
                        Color(red: 0.04, green: 0.06, blue: 0.11),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

struct ProfileCard: View {
    let profile: ProfileStatus
    let showID: Bool
    let isSwitching: Bool
    let isSwitchDisabled: Bool
    let isActionsMenuOpen: Bool
    let onSwitch: () -> Void
    let onEditLabel: () -> Void
    let onClearLabel: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onToggleActionsMenu: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(toneColor.opacity(0.22))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(toneColor)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.primaryText)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        statusChip
                    }

                    if !profile.secondaryText.isEmpty {
                        Text(profile.secondaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }

                    if showID, let id = profile.id {
                        Text(id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    if profile.canSwitch {
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
                    } else {
                        Text(profile.isCurrent ? "Active" : "Saved")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }

                    Button {
                        onToggleActionsMenu()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(isActionsMenuOpen ? 180 : 0))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: ActionsMenuButtonFramePreferenceKey.self,
                                    value: [profile.stableID: proxy.frame(in: .named(menuBarRootCoordinateSpace))]
                                )
                        }
                    }
                }
            }

            if let usage = profile.usage, usage.state == "ok", let bucket = profile.primaryUsageBucket {
                VStack(spacing: 8) {
                    UsageMeterRow(title: bucket.label, windowTitle: "5h", window: bucket.fiveHour)
                    UsageMeterRow(title: bucket.label, windowTitle: "Weekly", window: bucket.weekly)
                }
            }

            Text(profile.statusLabel)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(3)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke((isSwitching ? Color(red: 0.42, green: 0.97, blue: 0.77) : toneColor).opacity(isSwitching ? 0.7 : 0.35), lineWidth: isSwitching ? 1.5 : 1)
                )
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isSwitching)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isActionsMenuOpen)
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
}

struct ProfileActionsMenu: View {
    static let menuWidth: CGFloat = 170
    static let baseHeight: CGFloat = 144
    static let clearLabelExtraHeight: CGFloat = 44
    static let unsavedHeight: CGFloat = 68

    let profile: ProfileStatus
    let isClearingLabel: Bool
    let onEditLabel: () -> Void
    let onClearLabel: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if profile.isSaved {
                ActionMenuButton(title: "Edit label", symbol: "pencil", role: .normal, action: onEditLabel)

                if profile.label != nil {
                    ActionMenuButton(
                        title: isClearingLabel ? "Clearing…" : "Clear label",
                        symbol: "tag.slash",
                        role: .normal,
                        isLoading: isClearingLabel,
                        action: onClearLabel
                    )
                }

                ActionMenuButton(title: "Export JSON", symbol: "square.and.arrow.up", role: .normal, action: onExport)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                ActionMenuButton(title: "Delete profile", symbol: "trash", role: .destructive, action: onDelete)
            } else {
                Text("Save current session first")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .padding(8)
        .frame(width: Self.menuWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.13, blue: 0.20))
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    static func estimatedHeight(for profile: ProfileStatus) -> CGFloat {
        if !profile.isSaved {
            return unsavedHeight
        }

        return baseHeight + (profile.label != nil ? clearLabelExtraHeight : 0)
    }
}

struct ActionsMenuButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ActionMenuButton: View {
    enum Role {
        case normal
        case destructive
    }

    let title: String
    let symbol: String
    let role: Role
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(role == .destructive ? Color(red: 1.0, green: 0.53, blue: 0.53) : .white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
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

struct SettingsView: View {
    @ObservedObject var model: CodexProfilesViewModel
    @AppStorage(Preferences.showIDsKey) private var showIDs = false
    @AppStorage(Preferences.autoRefreshKey) private var autoRefreshEnabled = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.97, blue: 0.99),
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                ],
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
                }
                .padding(24)
            }
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CodexProfilesBar Settings")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.23))
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
                                .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.23))
                            Text(model.launchAtLoginState.detail)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.44, blue: 0.52))
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

                Text("If profiles do not appear, sign in once with `codex login` so ~/.codex/auth.json is available.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color(red: 0.40, green: 0.44, blue: 0.52))
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
                        Text("Keeps usage and status fresh while the app is running.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color(red: 0.40, green: 0.44, blue: 0.52))
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(Color(red: 0.32, green: 0.55, blue: 0.95))

                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.23))

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color(red: 0.38, green: 0.41, blue: 0.50))
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.92))
                .shadow(color: Color.black.opacity(0.05), radius: 16, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(Color(red: 0.33, green: 0.36, blue: 0.44))

            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .system(.caption, design: .rounded))
                .foregroundStyle(Color(red: 0.20, green: 0.23, blue: 0.30))
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

    var body: some View {
        let percent = max(0, min(100, window?.leftPercent ?? 0))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(windowTitle)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                if let window {
                    Text("\(percent)% left · resets \(window.relativeResetText())")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                } else {
                    Text("No \(title.lowercased()) data")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.13, green: 0.77, blue: 0.55),
                                    Color(red: 0.19, green: 0.94, blue: 0.71),
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

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(.caption, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.66))
                .frame(maxWidth: 300)
        }
    }
}

struct BannerView: View {
    let message: BannerMessage
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message.body)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close notification")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
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

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRefreshing ? Color.white.opacity(0.16) : Color.white.opacity(0.10))

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.39, green: 0.98, blue: 0.78))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
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

    var body: some View {
        if isRefreshing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(red: 0.43, green: 0.96, blue: 0.76))
                Text("Refreshing")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(Color(red: 0.43, green: 0.96, blue: 0.76))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
    }
}

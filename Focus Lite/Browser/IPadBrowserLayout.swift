//
//  IPadBrowserLayout.swift
//  Focus Lite
//

import SwiftUI

/// Large-screen layout for iPad: a persistent tab sidebar beside the page,
/// with the browser controls in a toolbar above the content.
struct IPadBrowserLayout: View {
    @ObservedObject var manager: TabManager
    @FocusState private var addressFocused: Bool
    @State private var showTrackerTip = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                topBar

                if let model = manager.activeTab?.model {
                    ProgressBar(model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                if manager.isIncognito {
                    IncognitoPill()
                        .padding(.bottom, 6)
                }
                TabContentView(manager: manager)

                if showTrackerTip, let model = manager.activeTab?.model {
                    TrackerTip(model: model)
                        .padding(.bottom, 10)
                        .onTapGesture { withAnimation { showTrackerTip = false } }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let toastText = manager.toastText {
                    StatusToast(text: toastText, symbol: manager.toastSymbol,
                                actionTitle: manager.toastActionTitle) {
                        manager.allowPopupsForLastBlockedSite()
                    }
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.isIncognito)
        .onAppear { manager.captureTabPreviews() }
        .onDisappear { manager.clearTabPreviews() }
        .onChange(of: manager.pagesVisited) { _, _ in manager.captureActiveTabPreview() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Focus Lite")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation { manager.toggleIncognito() }
                } label: {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(manager.isIncognito ? Theme.incognito : Color.white)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(manager.tabs) { tab in
                        TabRow(manager: manager, model: tab.model, tabID: tab.id)
                    }
                }
            }

            Button {
                withAnimation { _ = manager.addTab() }
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer()

            Divider()
            HStack(spacing: 10) {
                Button(action: manager.erase) {
                    Label("Erase", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Button { manager.showSettings = true } label: {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 264)
        .background(Color(white: 1, opacity: 0.04))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if let model = manager.activeTab?.model {
                if !model.isStart {
                    Button(action: model.goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(!model.canGoBack)
                    .opacity(model.canGoBack ? 1 : 0.3)

                    Button(action: model.toggleReload) {
                        Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }

                AddressField(model: model, showTrackerTip: $showTrackerTip,
                             addressFocused: $addressFocused)
                    .frame(maxWidth: 640)

                Spacer()

                Button(action: manager.erase) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Button { manager.showSettings = true } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

private struct TabRow: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var model: BrowserModel
    let tabID: Tab.ID

    private var isActive: Bool { tabID == manager.activeTabID }

    var body: some View {
        HStack(spacing: 8) {
            if let image = model.previewImage, !model.isStart {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: model.isStart ? "shield.lefthalf.filled" : "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.accent : Color.secondary)
            }
            Text(model.displayedURL?.host ?? "Start Page")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button {
                withAnimation { manager.close(tabID) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.12 : 0.0))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { manager.select(tabID) } }
    }
}

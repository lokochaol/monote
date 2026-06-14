//
//  MemoEditorView.swift
//  scroll
//

import Combine
import SwiftUI
import UIKit

// MARK: - Text view holder (reference type so @State doesn't copy)

private final class TextViewHolder {
    weak var textView: UITextView?
}

// MARK: - Main editor view

struct MemoEditorView: View {
    @State private var model = MemoEditorViewModel()
    @State private var showSearch = false
    @State private var didBootstrap = false
    @State private var keyboardTopScreenY: CGFloat?
    @State private var textViewHolder = TextViewHolder()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MemoJournalPalette.paperBackground()
                MemoDocumentTextView(
                    contentVersion: model.contentVersion,
                    attributed: model.attributedContent,
                    highlightQuery: model.searchHighlightKeyword,
                    scrollToRange: model.scrollToRange,
                    onAttributedEdit: { attr in
                        model.updateContent(attributed: attr)
                    },
                    onUndoStateChanged: { canUndo, canRedo in
                        model.updateUndoState(canUndo: canUndo, canRedo: canRedo)
                    },
                    onScrollPerformed: {
                        model.clearScrollToRange()
                    },
                    onTextViewReady: { tv in
                        textViewHolder.textView = tv
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if !model.isBootstrapped {
                    MemoDocInitialBootLoadingOverlay()
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardTopScreenY == nil {
                    bottomSearchEntryBar
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if model.isBootstrapped {
                        Button(action: performUndo) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .disabled(!model.canUndo)
                        .accessibilityLabel(Text("Undo"))

                        Button(action: performRedo) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .disabled(!model.canRedo)
                        .accessibilityLabel(Text("Redo"))
                    }
                }
                ToolbarItem(placement: .principal) {
                    if model.isBootstrapped {
                        MemoICloudStatusButton(
                            status: model.iCloudStatus,
                            isTransferring: model.iCloudTransferActive,
                            onToggle: { newValue in
                                await model.toggleICloudSync(enabled: newValue)
                            },
                            onFetchDiagnostics: {
                                await model.fetchStorageDiagnostics()
                            },
                            onEvictUnused: {
                                await model.evictUnusedICloudItems()
                            }
                        )
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .automatic)
            .onAppear {
                if !didBootstrap {
                    didBootstrap = true
                    model.attachSyncCoordinator(NoOpMemoSyncCoordinator.shared)
                    Task { @MainActor in
                        await model.bootstrap()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenH = UIScreen.main.bounds.height
                keyboardTopScreenY = frame.minY >= screenH - 0.5 ? nil : frame.minY
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTopScreenY = nil
            }
            .onReceive(Timer.publish(every: 2.5, tolerance: 0.5, on: .main, in: .common).autoconnect()) { _ in
                guard model.isBootstrapped, model.iCloudStatus == .synced else { return }
                Task { await model.refreshICloudTransferState() }
            }
            .sheet(isPresented: $showSearch) {
                MemoDocKeywordSearchSheet(model: model, isPresented: $showSearch)
            }
        }
    }

    // MARK: - Undo / Redo

    private func performUndo() {
        textViewHolder.textView?.undoManager?.undo()
        model.updateUndoState(
            canUndo: textViewHolder.textView?.undoManager?.canUndo ?? false,
            canRedo: textViewHolder.textView?.undoManager?.canRedo ?? false
        )
    }

    private func performRedo() {
        textViewHolder.textView?.undoManager?.redo()
        model.updateUndoState(
            canUndo: textViewHolder.textView?.undoManager?.canUndo ?? false,
            canRedo: textViewHolder.textView?.undoManager?.canRedo ?? false
        )
    }

    // MARK: - Bottom search entry bar

    private var bottomSearchEntryBar: some View {
        let q = model.searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            showSearch = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(q.isEmpty ? "Search" : q)
                    .font(.body)
                    .foregroundStyle(q.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(fieldShape)
            .glassEffect(.regular, in: fieldShape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MemoJournalPalette.horizontalInset)
        .padding(.bottom, 8)
    }
}

// MARK: - Keyword search sheet

private struct MemoDocKeywordSearchSheet: View {
    @Bindable var model: MemoEditorViewModel
    @Binding var isPresented: Bool
    @FocusState private var keywordFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Keyword", text: $model.searchKeywordText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .focused($keywordFieldFocused)
                    .submitLabel(.search)
                    .onChange(of: model.searchKeywordText) { _, _ in
                        model.scheduleSearchHitRefresh()
                    }
                if let msg = model.searchMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                List {
                    ForEach(model.searchHits) { hit in
                        Button {
                            model.selectSearchHit(hit)
                            isPresented = false
                        } label: {
                            MemoDocSearchHitRow(hit: hit, keyword: trimmedKeyword)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
            .onAppear {
                model.refreshSearchHits()
                keywordFieldFocused = true
            }
        }
    }

    private var trimmedKeyword: String {
        model.searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Search hit row

private struct MemoDocSearchHitRow: View {
    let hit: MemoDocSearchHit
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !hit.contextBefore.isEmpty {
                Text(highlightedString(hit.contextBefore, dimmed: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            Text(highlightedString(hit.matchText, dimmed: false))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            if !hit.contextAfter.isEmpty {
                Text(highlightedString(hit.contextAfter, dimmed: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func highlightedString(_ text: String, dimmed: Bool) -> AttributedString {
        let display = text.isEmpty ? " " : text
        var a = AttributedString(display)
        a.font = .subheadline
        a.foregroundColor = dimmed ? .secondary : .primary
        guard !keyword.isEmpty, !text.isEmpty else { return a }
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: keyword, options: .caseInsensitive, range: search)
            if r.location == NSNotFound { break }
            if let swiftRange = Range(r, in: text),
               let low = AttributedString.Index(swiftRange.lowerBound, within: a),
               let high = AttributedString.Index(swiftRange.upperBound, within: a) {
                a[low ..< high].backgroundColor = Color.yellow.opacity(0.42)
            }
            let next = r.location + max(1, r.length)
            search = NSRange(location: next, length: ns.length - next)
        }
        return a
    }
}

// MARK: - Boot loading overlay

private struct MemoDocInitialBootLoadingOverlay: View {
    private let dotCount = 5
    private let dotSize: CGFloat = 11
    private let dotSpacing: CGFloat = 14
    private let bounceHeight: CGFloat = 13

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate * 4.8
                HStack(spacing: dotSpacing) {
                    ForEach(0 ..< dotCount, id: \.self) { i in
                        let phase = t + Double(i) * 0.62
                        let bounce = pow(max(0, sin(phase)), 2.0)
                        Circle()
                            .fill(Color.black.opacity(0.9))
                            .frame(width: dotSize, height: dotSize)
                            .offset(y: -CGFloat(bounce) * bounceHeight)
                    }
                }
            }
        }
        .accessibilityLabel(Text("Loading"))
    }
}

#Preview {
    MemoEditorView()
}

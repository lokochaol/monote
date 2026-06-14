//
//  MemoDocumentTextView.swift
//  scroll
//

import ImageIO
import PhotosUI
import SVGKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - Document-level wrapping text view

final class MemoDocumentWrappingTextView: UITextView, UIGestureRecognizerDelegate {
    private let imageTap = UITapGestureRecognizer()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupImageTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupImageTap()
    }

    override var textInputContextIdentifier: String? { "scroll.memo.document" }

    private func setupImageTap() {
        imageTap.addTarget(self, action: #selector(handleImageTap(_:)))
        imageTap.numberOfTapsRequired = 1
        imageTap.cancelsTouchesInView = false
        imageTap.delaysTouchesBegan = false
        imageTap.delaysTouchesEnded = false
        imageTap.delegate = self
        addGestureRecognizer(imageTap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === imageTap {
            let pt = touch.location(in: self)
            return attachmentAndIndex(at: pt) != nil
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === imageTap
    }

    private func attachmentAndIndex(at viewPoint: CGPoint) -> (NSTextAttachment, Int)? {
        let layoutManager = self.layoutManager
        let textContainer = self.textContainer
        var point = viewPoint
        point.x -= textContainerInset.left
        point.y -= textContainerInset.top
        point.x -= textContainer.lineFragmentPadding
        var fraction: CGFloat = 0
        let idx = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard idx >= 0, idx < textStorage.length else { return nil }
        guard let att = textStorage.attribute(.attachment, at: idx, effectiveRange: nil) as? NSTextAttachment else { return nil }
        let charRange = NSRange(location: idx, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.contains(point) ? (att, idx) : nil
    }

    @objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let pt = gesture.location(in: self)
        guard let (att, idx) = attachmentAndIndex(at: pt) else { return }
        if let chip = att as? MemoLinkChipAttachment {
            let linkVal = textStorage.attribute(.link, at: idx, effectiveRange: nil)
            guard let url = MemoLinkChipInsertion.openableHTTPURL(from: chip, linkAttribute: linkVal) else { return }
            MemoLinkChipInsertion.openInBrowser(url)
            return
        }
        MemoImageInsertion.presentFullscreen(for: att, from: self)
    }

    func insertWithTypingAttributes(_ string: String, uniformBold: Bool? = nil) {
        guard markedTextRange == nil else { return }
        let sel = selectedRange
        var attrs = typingAttributes
        if let uniformBold {
            let baseFont = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            attrs[.font] = baseFont.memoDocFontWithUniformBold(uniformBold)
        }
        let insertion = NSAttributedString(string: string, attributes: attrs)
        textStorage.replaceCharacters(in: sel, with: insertion)
        selectedRange = NSRange(location: sel.location + (string as NSString).length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(keyCommandInsertTab(_:)))
        tab.wantsPriorityOverSystemBehavior = true
        return [tab]
    }

    @objc private func keyCommandInsertTab(_ sender: UIKeyCommand) {
        insertWithTypingAttributes("\t")
    }

    override func paste(_ sender: Any?) {
        if let svgData = Self.pasteboardSVGData(), MemoSVGInsertion.insertSVG(data: svgData, into: self) {
            return
        }
        if let img = UIPasteboard.general.image {
            MemoImageInsertion.insertImage(img, into: self)
            return
        }
        guard let s = UIPasteboard.general.string, !s.isEmpty else {
            super.paste(sender)
            return
        }
        if let sniffed = MemoSVGInsertion.sniffedSVGData(fromString: s),
           MemoSVGInsertion.insertSVG(data: sniffed, into: self) {
            return
        }
        if let url = MemoLinkChipInsertion.lonePastedWebURL(s) {
            let attrs = MemoRichTextEncoding.defaultTypingAttributes()
            typingAttributes = attrs
            MemoLinkChipInsertion.insertLinkChip(for: url, into: self)
            return
        }
        let attrs = MemoRichTextEncoding.defaultTypingAttributes()
        typingAttributes = attrs
        let selected = selectedRange
        let insertion = NSAttributedString(string: s, attributes: attrs)
        textStorage.replaceCharacters(in: selected, with: insertion)
        selectedRange = NSRange(location: selected.location + (s as NSString).length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    static func pasteboardSVGData() -> Data? {
        let svgTypes = ["public.svg-image", "org.w3.scalable-vector-graphics-xml"]
        let pb = UIPasteboard.general
        for type in svgTypes {
            if let d = pb.data(forPasteboardType: type), !d.isEmpty { return d }
        }
        return nil
    }
}

private extension UIFont {
    func memoDocFontWithUniformBold(_ bold: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        guard let desc = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
    }
}

// MARK: - SwiftUI wrapper

struct MemoDocumentTextView: UIViewRepresentable {
    let contentVersion: Int
    let attributed: NSAttributedString
    var highlightQuery: String?
    var scrollToRange: NSRange?

    var onAttributedEdit: (NSAttributedString) -> Void
    var onUndoStateChanged: (Bool, Bool) -> Void = { _, _ in }
    var onScrollPerformed: (() -> Void)?
    var onTextViewReady: ((UITextView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MemoDocumentWrappingTextView {
        let tv = MemoDocumentWrappingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.allowsEditingTextAttributes = true
        let attrs = MemoRichTextEncoding.defaultTypingAttributes()
        tv.typingAttributes = attrs
        tv.attributedText = attributed
        tv.textContainer.lineFragmentPadding = 4
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 24, right: 12)
        tv.textContentType = nil
        tv.passwordRules = nil
        tv.smartInsertDeleteType = .yes
        tv.isScrollEnabled = true
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true

        let accessory = MemoRichTextKeyboardAccessoryView()
        accessory.attach(to: tv)
        accessory.setAccentColors(MemoJournalPalette.formatBarUIColors())
        tv.inputAccessoryView = accessory
        context.coordinator.accessory = accessory

        context.coordinator.startObservingKeyboard(for: tv)
        onTextViewReady?(tv)

        // Scroll to end after layout settles
        let len = attributed.length
        DispatchQueue.main.async { [weak tv] in
            guard let tv else { return }
            tv.selectedRange = NSRange(location: len, length: 0)
            tv.scrollRangeToVisible(NSRange(location: len, length: 0))
            if !tv.isFirstResponder {
                _ = tv.becomeFirstResponder()
            }
        }

        return tv
    }

    func updateUIView(_ uiView: MemoDocumentWrappingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        // Refresh accessory accent colors (once)
        if !coord.didApplyAccentColors {
            coord.accessory?.setAccentColors(MemoJournalPalette.formatBarUIColors())
            coord.didApplyAccentColors = true
        }

        // Apply new content only when version changes (initial load / explicit reload)
        if coord.lastAppliedContentVersion != contentVersion {
            coord.lastAppliedContentVersion = contentVersion
            uiView.attributedText = attributed
            let len = attributed.length
            DispatchQueue.main.async { [weak uiView] in
                guard let tv = uiView else { return }
                tv.selectedRange = NSRange(location: len, length: 0)
                tv.scrollRangeToVisible(NSRange(location: len, length: 0))
                if !tv.isFirstResponder {
                    _ = tv.becomeFirstResponder()
                }
            }
            return
        }

        // Apply search highlight (non-editing, overlay on copy)
        if !uiView.isFirstResponder, let q = highlightQuery, !q.isEmpty {
            let base = uiView.attributedText ?? NSAttributedString()
            if coord.lastHighlightQuery != q || coord.lastHighlightSourceLength != base.length {
                coord.lastHighlightQuery = q
                coord.lastHighlightSourceLength = base.length
                let highlighted = Self.makeHighlighted(attr: base, query: q, alpha: 0.45)
                if !uiView.isFirstResponder {
                    uiView.attributedText = highlighted
                }
            }
        } else if coord.lastHighlightQuery != nil {
            // Clear highlights when there's no query
            coord.lastHighlightQuery = nil
            coord.lastHighlightSourceLength = -1
        }

        // Scroll to a specific range (search hit navigation)
        if let range = scrollToRange, coord.lastScrollToRange != range {
            coord.lastScrollToRange = range
            uiView.scrollRangeToVisible(range)
            uiView.selectedRange = range
            onScrollPerformed?()
        }

        // Refresh link chip metadata
        MemoLinkChipInsertion.scheduleMetadataRefresh(in: uiView)
    }

    private static func makeHighlighted(attr: NSAttributedString, query: String, alpha: CGFloat) -> NSMutableAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let plain = m.string as NSString
        let fullLen = plain.length
        guard !query.isEmpty, fullLen > 0 else { return m }
        var search = NSRange(location: 0, length: fullLen)
        while search.length > 0 {
            let r = plain.range(of: query, options: .caseInsensitive, range: search)
            if r.location == NSNotFound { break }
            m.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(alpha), range: r)
            let next = r.location + max(1, r.length)
            search = NSRange(location: next, length: fullLen - next)
        }
        return m
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MemoDocumentTextView
        weak var accessory: MemoRichTextKeyboardAccessoryView?
        var lastAppliedContentVersion: Int = -1
        var didApplyAccentColors: Bool = false
        var lastHighlightQuery: String?
        var lastHighlightSourceLength: Int = -1
        var lastScrollToRange: NSRange?

        private weak var managedTextView: MemoDocumentWrappingTextView?
        private var keyboardObservers: [NSObjectProtocol] = []

        init(_ parent: MemoDocumentTextView) {
            self.parent = parent
        }

        deinit {
            keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func startObservingKeyboard(for textView: MemoDocumentWrappingTextView) {
            managedTextView = textView
            guard keyboardObservers.isEmpty else { return }
            let center = NotificationCenter.default
            keyboardObservers = [
                center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                    self?.handleKeyboardWillChangeFrame(note)
                },
                center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                    self?.handleKeyboardWillHide(note)
                }
            ]
        }

        private func handleKeyboardWillChangeFrame(_ note: Notification) {
            guard let tv = managedTextView,
                  let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let tvFrameInWindow = tv.convert(tv.bounds, to: nil)
            let overlap = max(0, tvFrameInWindow.maxY - endFrame.minY)
            animateInsets(tv, bottom: overlap, note: note)
        }

        private func handleKeyboardWillHide(_ note: Notification) {
            guard let tv = managedTextView else { return }
            animateInsets(tv, bottom: 0, note: note)
        }

        private func animateInsets(_ tv: UITextView, bottom: CGFloat, note: Notification) {
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0) << 16
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: UIView.AnimationOptions(rawValue: curveRaw).union(.beginFromCurrentState)
            ) {
                tv.contentInset.bottom = bottom
                tv.verticalScrollIndicatorInsets.bottom = bottom
            } completion: { _ in
                // Scroll cursor into the now-visible area above the keyboard
                if bottom > 0 {
                    tv.scrollRangeToVisible(tv.selectedRange)
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onAttributedEdit(textView.attributedText ?? NSAttributedString())
            parent.onUndoStateChanged(
                textView.undoManager?.canUndo ?? false,
                textView.undoManager?.canRedo ?? false
            )
            // Keep cursor visible as content grows
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            accessory?.resetToStyleMode()
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .textAttachment(let attachment) = textItem.content else { return defaultAction }
            if let chip = attachment as? MemoLinkChipAttachment {
                return UIAction { [weak textView] _ in
                    guard let tv = textView else { return }
                    var chipIndex: Int?
                    tv.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage.length), options: []) { value, range, stop in
                        guard (value as AnyObject) === (chip as AnyObject) else { return }
                        chipIndex = range.location
                        stop.pointee = true
                    }
                    let linkVal = chipIndex.map { tv.textStorage.attribute(.link, at: $0, effectiveRange: nil) }
                    guard let url = MemoLinkChipInsertion.openableHTTPURL(from: chip, linkAttribute: linkVal ?? nil) else { return }
                    MemoLinkChipInsertion.openInBrowser(url)
                }
            }
            return UIAction { _ in
                MemoImageInsertion.presentFullscreen(for: attachment, from: textView)
            }
        }
    }
}

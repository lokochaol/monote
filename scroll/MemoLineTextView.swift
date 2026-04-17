//
//  MemoLineTextView.swift
//  scroll
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - プレビュー枠を固定（モーダル後に `bounds` が 0 に戻って実寸表示になるのを防ぐ）

@objc(MemoPreviewImageAttachment)
private final class MemoPreviewImageAttachment: NSTextAttachment {
	private static let codingPreviewW = "MemoInlinePreviewW"
	private static let codingPreviewH = "MemoInlinePreviewH"

	/// レイアウト用の表示枠。`bounds` が無効でも `attachmentBounds` はここを使う。
	var previewLayoutSize: CGSize

	init(image: UIImage, previewLayoutSize: CGSize) {
		self.previewLayoutSize = previewLayoutSize
		super.init(data: nil, ofType: nil)
		self.image = image
	}

	/// 復元経路（RTF / アーカイブ / コピー等）で呼ばれることがあるため受ける。
	override init(data contentData: Data?, ofType uti: String?) {
		self.previewLayoutSize = .zero
		super.init(data: contentData, ofType: uti)
		if previewLayoutSize == .zero {
			if bounds.width > 0, bounds.height > 0 {
				previewLayoutSize = bounds.size
			} else {
				previewLayoutSize = CGSize(width: 120, height: 120)
			}
		}
	}

	required init?(coder: NSCoder) {
		self.previewLayoutSize = .zero
		super.init(coder: coder)
		if coder.containsValue(forKey: Self.codingPreviewW), coder.containsValue(forKey: Self.codingPreviewH) {
			previewLayoutSize = CGSize(
				width: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewW)),
				height: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewH))
			)
		} else if bounds.width > 0, bounds.height > 0 {
			previewLayoutSize = bounds.size
		} else {
			previewLayoutSize = CGSize(width: 120, height: 120)
		}
	}

	override class var supportsSecureCoding: Bool { true }

	override func encode(with coder: NSCoder) {
		super.encode(with: coder)
		coder.encode(Double(previewLayoutSize.width), forKey: Self.codingPreviewW)
		coder.encode(Double(previewLayoutSize.height), forKey: Self.codingPreviewH)
	}

	override func attachmentBounds(
		for textContainer: NSTextContainer?,
		proposedLineFragment lineFrag: CGRect,
		glyphPosition position: CGPoint,
		characterIndex charIndex: Int
	) -> CGRect {
		let w = previewLayoutSize.width
		let h = previewLayoutSize.height
		guard w > 0, h > 0,
		      let lm = textContainer?.layoutManager,
		      let ts = lm.textStorage,
		      ts.length > 0
		else {
			if bounds.width > 0, bounds.height > 0 { return bounds }
			return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
		}
		let idx = min(max(0, charIndex), ts.length - 1)
		let font = ts.attribute(.font, at: idx, effectiveRange: nil) as? UIFont ?? UIFont.preferredFont(forTextStyle: .body)
		let midY = (font.capHeight - h) / 2
		return CGRect(x: 0, y: midY, width: w, height: h)
	}
}

// MARK: - 画像挿入（レイアウト枠だけ小さく＝表面上のサムネ／タップでフルスクリーン）

enum MemoImageInsertion {
	private static let previewMaxWidth: CGFloat = 152
	private static let previewMinWidth: CGFloat = 88
	private static let previewWidthFraction: CGFloat = 0.38
	/// プレビュー枠の最大高さ（縦長写真で行が伸びすぎないように）
	private static let previewMaxHeight: CGFloat = 200

	/// 画像は解像度そのまま `attachment.image` に載せ、**表示サイズは `bounds` のみ**で抑える（別解像度のプレビュー用ビットマップは作らない）。
	static func insertImage(_ image: UIImage, into textView: UITextView) {
		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)
		let previewCap = min(previewMaxWidth, max(previewMinWidth, containerW * previewWidthFraction))
		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)

		let iw = max(image.size.width, 1)
		let ih = max(image.size.height, 1)

		var displayW = previewCap
		var displayH = displayW * (ih / iw)
		if displayH > previewMaxHeight {
			displayH = previewMaxHeight
			displayW = displayH * (iw / ih)
		}

		let midY = (font.capHeight - displayH) / 2
		let attachment = MemoPreviewImageAttachment(image: image, previewLayoutSize: CGSize(width: displayW, height: displayH))
		attachment.bounds = CGRect(x: 0, y: midY, width: displayW, height: displayH)

		let attrString = NSMutableAttributedString(attachment: attachment)
		let baseAttrs = MemoRichTextEncoding.defaultTypingAttributes()
		attrString.addAttributes(baseAttrs, range: NSRange(location: 0, length: attrString.length))

		let sel = textView.selectedRange
		textView.textStorage.replaceCharacters(in: sel, with: attrString)
		textView.selectedRange = NSRange(location: sel.location + attrString.length, length: 0)
		textView.invalidateIntrinsicContentSize()
		textView.delegate?.textViewDidChange?(textView)
	}

	/// 旧データは `contents` にフル解像度があることがある。新データは `image` のみ。
	static func fullImage(from attachment: NSTextAttachment) -> UIImage? {
		if let data = attachment.contents, let img = UIImage(data: data) {
			return img
		}
		return attachment.image
	}

	static func presentFullscreen(for attachment: NSTextAttachment, from view: UIView) {
		guard let img = fullImage(from: attachment) else { return }
		guard let host = view.memoContainingViewController() else { return }
		let sheet = MemoFullscreenImageViewController(image: img)
		host.present(sheet, animated: true)
	}
}

extension UIView {
	fileprivate func memoContainingViewController() -> UIViewController? {
		var r: UIResponder? = self
		while let cur = r {
			if let vc = cur as? UIViewController { return vc }
			r = cur.next
		}
		return nil
	}
}

/// 添付画像を画面いっぱいに表示（タップまたは閉じるで解除）
private final class MemoFullscreenImageViewController: UIViewController {
	private let image: UIImage

	init(image: UIImage) {
		self.image = image
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
		modalTransitionStyle = .crossDissolve
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black

		let iv = UIImageView(image: image)
		iv.contentMode = .scaleAspectFit
		iv.isUserInteractionEnabled = true
		iv.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(iv)
		let tapImage = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
		iv.addGestureRecognizer(tapImage)

		let close = UIButton(type: .close)
		close.translatesAutoresizingMaskIntoConstraints = false
		close.accessibilityLabel = "閉じる"
		close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
		view.addSubview(close)

		NSLayoutConstraint.activate([
			iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			iv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			iv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
			close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
			close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
		])

		let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
		tap.cancelsTouchesInView = false
		view.addGestureRecognizer(tap)
	}

	@objc private func closeTapped() {
		dismiss(animated: true)
	}
}

/// `SwiftUI` から渡される幅でテキストコンテナを揃え、行が横にはみ出さないようにする。
private final class MemoWrappingTextView: UITextView, UIGestureRecognizerDelegate {
	private let imageTap = UITapGestureRecognizer()

	override init(frame: CGRect, textContainer: NSTextContainer?) {
		super.init(frame: frame, textContainer: textContainer)
		setupImageTap()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupImageTap()
	}

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
		guard gestureRecognizer === imageTap else { return true }
		let pt = touch.location(in: self)
		return attachment(at: pt) != nil
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// テキスト編集（キャレット移動 / 選択）を邪魔しない
		gestureRecognizer === imageTap
	}

	private func attachment(at viewPoint: CGPoint) -> NSTextAttachment? {
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

		// `characterIndex(for:)` は近傍に吸い寄せられるため、添付の実矩形で厳密にヒットテストする。
		let charRange = NSRange(location: idx, length: 1)
		let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
		guard glyphRange.length > 0 else { return nil }
		let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
		return rect.contains(point) ? att : nil
	}

	@objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
		guard gesture.state == .ended else { return }
		let pt = gesture.location(in: self)
		guard let att = attachment(at: pt) else { return }
		MemoImageInsertion.presentFullscreen(for: att, from: self)
	}

	override func paste(_ sender: Any?) {
		if let img = UIPasteboard.general.image {
			MemoImageInsertion.insertImage(img, into: self)
			return
		}
		guard let s = UIPasteboard.general.string, !s.isEmpty else {
			super.paste(sender)
			return
		}

		let attrs = MemoRichTextEncoding.defaultTypingAttributes()
		typingAttributes = attrs

		let selected = selectedRange
		let insertion = NSAttributedString(string: s, attributes: attrs)
		textStorage.replaceCharacters(in: selected, with: insertion)
		selectedRange = NSRange(location: selected.location + (s as NSString).length, length: 0)

		invalidateIntrinsicContentSize()
		delegate?.textViewDidChange?(self)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		guard bounds.width > 0 else { return }
		let insetW = textContainerInset.left + textContainerInset.right + textContainer.lineFragmentPadding * 2
		let w = max(1, bounds.width - insetW)
		if abs(textContainer.size.width - w) > 0.5 {
			textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
			invalidateIntrinsicContentSize()
		}
	}
}

/// 純正メモのように選択範囲へ太字・文字色を付けられる 1 行エディタ（`UITextView` + RTF 永続化）
struct MemoLineTextView: UIViewRepresentable {
	let rtfData: Data?
	let archiveData: Data?
	let plainText: String
	var isFocused: Bool
	var highlightQuery: String?
	/// 検索ハイライトの濃さ（0...1）。nil の場合は既定値。
	var highlightAlpha: CGFloat?
	@Binding var pendingCaretUTF16: Int?

	var onAttributedEdit: (NSAttributedString) -> Void
	var onInsertLineBreak: (NSAttributedString, NSRange) -> Void
	var onBackspaceAtBeginning: () -> Void
	var onEditingBegan: () -> Void = {}
	var onSelectionInteraction: (_ selectionLength: Int) -> Void = { _ in }

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	func makeUIView(context: Context) -> UITextView {
		let tv = MemoWrappingTextView()
		tv.delegate = context.coordinator
		tv.backgroundColor = .clear
		tv.allowsEditingTextAttributes = true
		let attrs = MemoRichTextEncoding.defaultTypingAttributes()
		tv.typingAttributes = attrs
		tv.attributedText = MemoRichTextEncoding.attributedString(rtfData: rtfData, archiveData: archiveData, plainFallback: plainText)
		tv.textContainer.lineFragmentPadding = 0
		tv.textContainer.widthTracksTextView = false
		tv.isScrollEnabled = false
		tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		tv.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
		tv.textContentType = nil
		tv.passwordRules = nil
		tv.smartInsertDeleteType = .yes
		tv.keyboardDismissMode = .none

		let accessory = MemoRichTextKeyboardAccessoryView()
		accessory.attach(to: tv)
		accessory.setAccentColors(MemoJournalPalette.formatBarUIColors())
		tv.inputAccessoryView = accessory

		context.coordinator.accessory = accessory
		return tv
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
		guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
		let insetW = uiView.textContainerInset.left + uiView.textContainerInset.right + uiView.textContainer.lineFragmentPadding * 2
		let cw = max(1, w - insetW)
		uiView.textContainer.size = CGSize(width: cw, height: .greatestFiniteMagnitude)
		let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
		return CGSize(width: w, height: h)
	}

	func updateUIView(_ uiView: UITextView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.accessory?.attach(to: uiView)
		context.coordinator.accessory?.setAccentColors(MemoJournalPalette.formatBarUIColors())

		let base = MemoRichTextEncoding.attributedString(rtfData: rtfData, archiveData: archiveData, plainFallback: plainText)
		let target: NSAttributedString = {
			if !isFocused, let q = highlightQuery, !q.isEmpty {
				return Self.makeHighlighted(attr: base, query: q, alpha: highlightAlpha)
			}
			return base
		}()

		let skipBodyReplace = uiView.isFirstResponder && isFocused && target.string == (uiView.text ?? "")
		if !skipBodyReplace {
			if !target.isEqual(to: uiView.attributedText) {
				uiView.attributedText = target
			}
		}

		if let off = pendingCaretUTF16 {
			let len = (uiView.text as NSString?)?.length ?? 0
			let clamped = max(0, min(off, len))
			uiView.selectedRange = NSRange(location: clamped, length: 0)
			let clearBinding = _pendingCaretUTF16
			DispatchQueue.main.async {
				clearBinding.wrappedValue = nil
			}
		}

		if isFocused != context.coordinator.lastSyncedIsFocused {
			context.coordinator.lastSyncedIsFocused = isFocused
			context.coordinator.scheduleResponderSync(wantFocus: isFocused, textView: uiView)
		}
	}

	private static func makeHighlighted(attr: NSAttributedString, query: String, alpha: CGFloat?) -> NSMutableAttributedString {
		let m = NSMutableAttributedString(attributedString: attr)
		let plain = m.string as NSString
		let fullLen = plain.length
		guard !query.isEmpty, fullLen > 0 else { return m }
		let a = max(0, min(alpha ?? 0.45, 1))
		var search = NSRange(location: 0, length: fullLen)
		while search.length > 0 {
			let r = plain.range(of: query, options: .caseInsensitive, range: search)
			if r.location == NSNotFound { break }
			m.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(a), range: r)
			let next = r.location + max(1, r.length)
			search = NSRange(location: next, length: fullLen - next)
		}
		return m
	}

	final class Coordinator: NSObject, UITextViewDelegate {
		var parent: MemoLineTextView
		var lastSyncedIsFocused: Bool?
		weak var accessory: MemoRichTextKeyboardAccessoryView?
		private var responderApplyWorkItem: DispatchWorkItem?

		deinit {
			responderApplyWorkItem?.cancel()
		}

		func scheduleResponderSync(wantFocus: Bool, textView: UITextView) {
			responderApplyWorkItem?.cancel()
			guard wantFocus else { return }
			let item = DispatchWorkItem { [weak textView] in
				guard let tv = textView else { return }
				if !tv.isFirstResponder {
					tv.becomeFirstResponder()
				}
			}
			responderApplyWorkItem = item
			DispatchQueue.main.async(execute: item)
		}

		init(_ parent: MemoLineTextView) {
			self.parent = parent
		}

		func textViewDidChange(_ textView: UITextView) {
			textView.invalidateIntrinsicContentSize()
			parent.onAttributedEdit(textView.attributedText)
		}

		func textViewDidBeginEditing(_ textView: UITextView) {
			parent.onEditingBegan()
		}

		func textViewDidEndEditing(_ textView: UITextView) {
			accessory?.resetToStyleMode()
		}

		func textViewDidChangeSelection(_ textView: UITextView) {
			guard textView.isFirstResponder, parent.isFocused else { return }
			parent.onSelectionInteraction(textView.selectedRange.length)
		}

		func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
			if text.isEmpty, range.location == 0, range.length == 0 {
				parent.onBackspaceAtBeginning()
				return false
			}
			if text == "\n" || text == "\r" {
				parent.onInsertLineBreak(textView.attributedText, range)
				return false
			}
			return true
		}

		func textView(
			_ textView: UITextView,
			shouldInteractWith textAttachment: NSTextAttachment,
			in characterRange: NSRange,
			interaction: UITextItemInteraction
		) -> Bool {
			guard interaction == .invokeDefaultAction else { return true }
			MemoImageInsertion.presentFullscreen(for: textAttachment, from: textView)
			return false
		}
	}
}

// MARK: - キーボード上ツールバー（2段階: 選択 → スタイル or 写真）

final class MemoRichTextKeyboardAccessoryView: UIView, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
	private enum Step {
		case root
		case style
		case photo
	}

	private weak var textView: UITextView?
	private var step: Step = .root

	private let contentStack = UIStackView()
	private let rootChoiceStack = UIStackView()
	private let styleScreenStack = UIStackView()
	private let photoScreenStack = UIStackView()
	private let styleStack = UIStackView()
	private let photoStack = UIStackView()
	private var accentButtons: [UIButton] = []
	private let toolbarHorizontalInset: CGFloat = 20
	private let touchTargetSize: CGFloat = 44
	private let chipVisualSize: CGFloat = 28

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = UIColor.secondarySystemBackground
		let topLine = UIView()
		topLine.backgroundColor = UIColor.separator
		topLine.translatesAutoresizingMaskIntoConstraints = false
		addSubview(topLine)

		rootChoiceStack.axis = .horizontal
		rootChoiceStack.alignment = .center
		rootChoiceStack.spacing = 12
		rootChoiceStack.distribution = .fillEqually
		rootChoiceStack.translatesAutoresizingMaskIntoConstraints = false

		let styleChoice = makeRootChipButton(accessibilityLabel: "文字スタイル") { b in
			b.setTitle("Aa", for: .normal)
			b.setTitleColor(.label, for: .normal)
			let base = UIFont.systemFont(ofSize: 20, weight: .semibold)
			b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
			b.titleLabel?.adjustsFontForContentSizeCategory = true
		}
		styleChoice.addTarget(self, action: #selector(goToStyleScreen), for: .touchUpInside)

		let photoChoice = makeRootChipButton(accessibilityLabel: "写真の挿入") { b in
			let symFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .medium))
			let cfg = UIImage.SymbolConfiguration(font: symFont, scale: .default)
			b.setImage(UIImage(systemName: "photo", withConfiguration: cfg), for: .normal)
			b.tintColor = .label
		}
		photoChoice.addTarget(self, action: #selector(goToPhotoScreen), for: .touchUpInside)

		rootChoiceStack.addArrangedSubview(styleChoice)
		rootChoiceStack.addArrangedSubview(photoChoice)

		styleStack.axis = .horizontal
		styleStack.alignment = .center
		styleStack.spacing = 10
		styleStack.distribution = .equalSpacing
		styleStack.translatesAutoresizingMaskIntoConstraints = false

		let backStyle = makeIconButton(systemName: "chevron.backward", accessibilityLabel: "戻る")
		backStyle.addTarget(self, action: #selector(goToRoot), for: .touchUpInside)

		let bold = makeIconButton(systemName: "bold", accessibilityLabel: "太字")
		bold.addTarget(self, action: #selector(boldTapped), for: .touchUpInside)

		let strike = makeIconButton(systemName: "strikethrough", accessibilityLabel: "取り消し線")
		strike.addTarget(self, action: #selector(strikeTapped), for: .touchUpInside)

		let reset = makeColorChipButton(accessibilityLabel: "標準の色")
		colorChipView(in: reset)?.backgroundColor = UIColor.label
		reset.addTarget(self, action: #selector(resetColorTapped), for: .touchUpInside)

		styleStack.addArrangedSubview(bold)
		styleStack.addArrangedSubview(strike)
		for _ in 0 ..< 3 {
			let b = makeColorChipButton(accessibilityLabel: "文字色")
			b.addTarget(self, action: #selector(colorChipTapped(_:)), for: .touchUpInside)
			accentButtons.append(b)
			styleStack.addArrangedSubview(b)
		}
		styleStack.addArrangedSubview(reset)

		styleScreenStack.axis = .horizontal
		styleScreenStack.alignment = .center
		styleScreenStack.spacing = 6
		styleScreenStack.distribution = .fill
		styleScreenStack.translatesAutoresizingMaskIntoConstraints = false
		styleScreenStack.addArrangedSubview(backStyle)
		styleScreenStack.addArrangedSubview(styleStack)

		photoStack.axis = .horizontal
		photoStack.alignment = .fill
		photoStack.spacing = 12
		photoStack.distribution = .fillEqually
		photoStack.translatesAutoresizingMaskIntoConstraints = false
		let backPhoto = makeIconButton(systemName: "chevron.backward", accessibilityLabel: "戻る")
		backPhoto.addTarget(self, action: #selector(goToRoot), for: .touchUpInside)
		let library = makeIconButton(systemName: "photo.on.rectangle.angled", accessibilityLabel: "ライブラリから選ぶ", fillsBarWidth: true)
		library.addTarget(self, action: #selector(libraryTapped), for: .touchUpInside)
		let camera = makeIconButton(systemName: "camera", accessibilityLabel: "カメラで撮影", fillsBarWidth: true)
		camera.addTarget(self, action: #selector(cameraTapped), for: .touchUpInside)
		camera.isHidden = !UIImagePickerController.isSourceTypeAvailable(.camera)
		photoStack.addArrangedSubview(library)
		photoStack.addArrangedSubview(camera)

		photoScreenStack.axis = .horizontal
		photoScreenStack.alignment = .center
		photoScreenStack.spacing = 6
		photoScreenStack.distribution = .fill
		photoScreenStack.translatesAutoresizingMaskIntoConstraints = false
		photoScreenStack.addArrangedSubview(backPhoto)
		photoScreenStack.addArrangedSubview(photoStack)

		contentStack.axis = .vertical
		contentStack.spacing = 0
		contentStack.translatesAutoresizingMaskIntoConstraints = false
		contentStack.addArrangedSubview(rootChoiceStack)
		contentStack.addArrangedSubview(styleScreenStack)
		contentStack.addArrangedSubview(photoScreenStack)
		addSubview(contentStack)

		NSLayoutConstraint.activate([
			topLine.topAnchor.constraint(equalTo: topAnchor),
			topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
			topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
			topLine.heightAnchor.constraint(equalToConstant: 1.0 / max(UITraitCollection.current.displayScale, 1)),
			contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: toolbarHorizontalInset),
			contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -toolbarHorizontalInset),
			contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
		])

		styleScreenStack.isHidden = true
		photoScreenStack.isHidden = true
		updateIntrinsicSize()
		autoresizingMask = [.flexibleWidth, .flexibleHeight]
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	private func updateIntrinsicSize() {
		let size = systemLayoutSizeFitting(
			CGSize(width: UIView.layoutFittingExpandedSize.width, height: 0),
			withHorizontalFittingPriority: .fittingSizeLevel,
			verticalFittingPriority: .fittingSizeLevel
		)
		let h = max(size.height, 48)
		frame = CGRect(x: 0, y: 0, width: 320, height: h)
	}

	func attach(to tv: UITextView) {
		textView = tv
	}

	func resetToStyleMode() {
		showStep(.root)
	}

	func setAccentColors(_ colors: [UIColor]) {
		for (i, b) in accentButtons.enumerated() where i < colors.count {
			colorChipView(in: b)?.backgroundColor = colors[i]
		}
	}

	private func showStep(_ newStep: Step) {
		step = newStep
		rootChoiceStack.isHidden = newStep != .root
		styleScreenStack.isHidden = newStep != .style
		photoScreenStack.isHidden = newStep != .photo
		updateIntrinsicSize()
		textView?.reloadInputViews()
	}

	@objc private func goToRoot() {
		showStep(.root)
	}

	@objc private func goToStyleScreen() {
		showStep(.style)
	}

	@objc private func goToPhotoScreen() {
		showStep(.photo)
	}

	private func makeRootChipButton(accessibilityLabel: String, content: (UIButton) -> Void) -> UIButton {
		let b = UIButton(type: .system)
		b.accessibilityLabel = accessibilityLabel
		b.translatesAutoresizingMaskIntoConstraints = false
		b.backgroundColor = .clear
		content(b)
		NSLayoutConstraint.activate([
			b.heightAnchor.constraint(equalToConstant: touchTargetSize)
		])
		return b
	}

	private func notifyContentChange() {
		guard let tv = textView else { return }
		tv.delegate?.textViewDidChange?(tv)
	}

	private func makeIconButton(systemName: String, accessibilityLabel: String, fillsBarWidth: Bool = false) -> UIButton {
		let b = UIButton(type: .system)
		let img = UIImage(systemName: systemName)
		b.setImage(img, for: .normal)
		b.accessibilityLabel = accessibilityLabel
		b.tintColor = .label
		b.translatesAutoresizingMaskIntoConstraints = false
		b.heightAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		if fillsBarWidth {
			b.setContentHuggingPriority(.defaultLow, for: .horizontal)
			b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
			b.imageView?.contentMode = .scaleAspectFit
		} else {
			b.widthAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		}
		return b
	}

	private func makeColorChipButton(accessibilityLabel: String) -> UIButton {
		let b = UIButton(type: .system)
		let chip = UIView()
		chip.isUserInteractionEnabled = false
		chip.layer.cornerRadius = chipVisualSize / 2
		chip.clipsToBounds = true
		b.translatesAutoresizingMaskIntoConstraints = false
		chip.translatesAutoresizingMaskIntoConstraints = false
		b.backgroundColor = .clear
		b.addSubview(chip)
		NSLayoutConstraint.activate([
			b.widthAnchor.constraint(equalToConstant: touchTargetSize),
			b.heightAnchor.constraint(equalToConstant: touchTargetSize),
			chip.centerXAnchor.constraint(equalTo: b.centerXAnchor),
			chip.centerYAnchor.constraint(equalTo: b.centerYAnchor),
			chip.widthAnchor.constraint(equalToConstant: chipVisualSize),
			chip.heightAnchor.constraint(equalToConstant: chipVisualSize)
		])
		b.accessibilityLabel = accessibilityLabel
		return b
	}

	private func colorChipView(in button: UIButton) -> UIView? {
		button.subviews.first(where: { $0 is UIView && !$0.isUserInteractionEnabled })
	}

	@objc private func boldTapped() {
		textView?.toggleBoldface(nil)
		notifyContentChange()
	}

	@objc private func strikeTapped() {
		guard let tv = textView else { return }
		let strikeVal = NSUnderlineStyle.single.rawValue
		let range = tv.selectedRange
		if range.length > 0 {
			let sub = tv.attributedText.attributedSubstring(from: range)
			var allStruck = true
			sub.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: sub.length)) { val, _, stop in
				if (val as? Int ?? 0) == 0 {
					allStruck = false
					stop.pointee = true
				}
			}
			if allStruck {
				tv.textStorage.removeAttribute(.strikethroughStyle, range: range)
			} else {
				tv.textStorage.addAttribute(.strikethroughStyle, value: strikeVal, range: range)
			}
		} else {
			var ta = tv.typingAttributes
			let cur = ta[.strikethroughStyle] as? Int ?? 0
			if cur == 0 {
				ta[.strikethroughStyle] = strikeVal
			} else {
				ta.removeValue(forKey: .strikethroughStyle)
			}
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func resetColorTapped() {
		guard let tv = textView else { return }
		let color = UIColor.label
		if tv.selectedRange.length > 0 {
			tv.textStorage.addAttribute(.foregroundColor, value: color, range: tv.selectedRange)
			tv.textStorage.removeAttribute(.strikethroughStyle, range: tv.selectedRange)
		} else {
			var ta = tv.typingAttributes
			ta[.foregroundColor] = color
			ta.removeValue(forKey: .strikethroughStyle)
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func colorChipTapped(_ sender: UIButton) {
		guard let tv = textView, let color = colorChipView(in: sender)?.backgroundColor else { return }
		if tv.selectedRange.length > 0 {
			tv.textStorage.addAttribute(.foregroundColor, value: color, range: tv.selectedRange)
		} else {
			var ta = tv.typingAttributes
			ta[.foregroundColor] = color
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func libraryTapped() {
		guard let host = textView?.memoContainingViewController() else { return }
		var config = PHPickerConfiguration()
		config.filter = .images
		config.selectionLimit = 1
		let picker = PHPickerViewController(configuration: config)
		picker.delegate = self
		host.present(picker, animated: true)
	}

	@objc private func cameraTapped() {
		guard UIImagePickerController.isSourceTypeAvailable(.camera),
		      let host = textView?.memoContainingViewController()
		else { return }
		let picker = UIImagePickerController()
		picker.sourceType = .camera
		picker.delegate = self
		host.present(picker, animated: true)
	}

	func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
		picker.dismiss(animated: true)
		guard let item = results.first else { return }
		item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
			guard let self, let img = obj as? UIImage else { return }
			DispatchQueue.main.async {
				guard let tv = self.textView else { return }
				MemoImageInsertion.insertImage(img, into: tv)
			}
		}
	}

	func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
		picker.dismiss(animated: true)
		if let img = info[.originalImage] as? UIImage, let tv = textView {
			MemoImageInsertion.insertImage(img, into: tv)
		}
	}

	func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
		picker.dismiss(animated: true)
	}
}

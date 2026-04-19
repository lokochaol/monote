//
//  MemoTimestampOptionsSheetViewController.swift
//  scroll
//

import UIKit

/// 日時の書式（プルダウン）・太字（`bold` シンボル＋スイッチ）をまとめて選ぶシート。
final class MemoTimestampOptionsSheetViewController: UIViewController, UIAdaptivePresentationControllerDelegate, UIPickerViewDataSource, UIPickerViewDelegate {
	private let scrollView = UIScrollView()
	private let contentStack = UIStackView()
	private let boldIcon = UIImageView()
	private let boldSwitch = UISwitch()

	private let formatMenuButton = UIButton(type: .system)
	private let customFieldsContainer = UIStackView()
	private let formatTextField = UITextField()
	private let localePicker = UIPickerView()

	/// メニューで「カスタム」を選んでいる間は true（保存値が偶然プリセットと一致していてもカスタム UI を出す）。
	private var selectionIsCustom: Bool

	override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
		self.selectionIsCustom = MemoTimestampSettings.matchingPresetIndex() == nil
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
	}

	convenience init() {
		self.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemGroupedBackground
		navigationItem.title = "Format"
		navigationItem.rightBarButtonItem = UIBarButtonItem(
			barButtonSystemItem: .done,
			target: self,
			action: #selector(doneTapped)
		)

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.alwaysBounceVertical = true
		view.addSubview(scrollView)

		contentStack.axis = .vertical
		contentStack.alignment = .fill
		contentStack.spacing = 14
		contentStack.translatesAutoresizingMaskIntoConstraints = false
		scrollView.addSubview(contentStack)

		contentStack.addArrangedSubview(makeTopHintStrip())

		let boldRow = UIStackView()
		boldRow.axis = .horizontal
		boldRow.alignment = .center
		boldRow.spacing = 16
		boldRow.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
		boldRow.isLayoutMarginsRelativeArrangement = true
		boldRow.backgroundColor = .secondarySystemGroupedBackground
		boldRow.layer.cornerRadius = 12
		boldRow.layer.cornerCurve = .continuous
		boldRow.clipsToBounds = true

		let sym = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
		boldIcon.image = UIImage(systemName: "bold", withConfiguration: sym)
		boldIcon.tintColor = .label
		boldIcon.setContentHuggingPriority(.required, for: .horizontal)
		boldIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
		boldIcon.isAccessibilityElement = false

		boldSwitch.isOn = MemoTimestampSettings.timestampUseBold
		boldSwitch.addTarget(self, action: #selector(boldSwitchChanged), for: .valueChanged)
		boldSwitch.accessibilityLabel = "Bold"

		let spacer = UIView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

		boldRow.addArrangedSubview(boldIcon)
		boldRow.addArrangedSubview(spacer)
		boldRow.addArrangedSubview(boldSwitch)
		applyBoldVisualState()
		contentStack.addArrangedSubview(boldRow)

		formatMenuButton.translatesAutoresizingMaskIntoConstraints = false
		formatMenuButton.showsMenuAsPrimaryAction = true
		formatMenuButton.contentHorizontalAlignment = .leading
		contentStack.addArrangedSubview(formatMenuButton)

		customFieldsContainer.axis = .vertical
		customFieldsContainer.spacing = 16
		customFieldsContainer.isLayoutMarginsRelativeArrangement = true
		customFieldsContainer.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)

		let dateFormatCaption = captionLabel("dateFormat")
		formatTextField.borderStyle = .roundedRect
		formatTextField.font = .preferredFont(forTextStyle: .body)
		formatTextField.placeholder = "yyyy.MM.dd EEE"
		formatTextField.autocorrectionType = .no
		formatTextField.autocapitalizationType = .none
		formatTextField.smartDashesType = .no
		formatTextField.smartQuotesType = .no
		let formatBlock = UIStackView(arrangedSubviews: [dateFormatCaption, formatTextField])
		formatBlock.axis = .vertical
		formatBlock.alignment = .fill
		formatBlock.spacing = 4

		let localeCaption = captionLabel("Locale Identifier")
		localePicker.dataSource = self
		localePicker.delegate = self
		localePicker.translatesAutoresizingMaskIntoConstraints = false
		let localeBlock = UIStackView(arrangedSubviews: [localeCaption, localePicker])
		localeBlock.axis = .vertical
		localeBlock.alignment = .fill
		localeBlock.spacing = 4
		localePicker.heightAnchor.constraint(equalToConstant: 148).isActive = true

		customFieldsContainer.addArrangedSubview(formatBlock)
		customFieldsContainer.addArrangedSubview(localeBlock)
		contentStack.addArrangedSubview(customFieldsContainer)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
			contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
			contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
			contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
			contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
		])

		presentationController?.delegate = self
		syncFormatUI()
	}

	/// 1行目: 電球＋説明 / 2行目: 日時アイコン・三点・Hold。虹色の縁取りで強調。
	private func makeTopHintStrip() -> UIView {
		let outer = UIStackView()
		outer.axis = .vertical
		outer.alignment = .fill
		outer.spacing = 12
		outer.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
		outer.isLayoutMarginsRelativeArrangement = true

		let row1 = UIStackView()
		row1.axis = .horizontal
		row1.alignment = .top
		row1.spacing = 10

		let bulbCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
		let bulb = UIImageView(image: UIImage(systemName: "lightbulb.fill", withConfiguration: bulbCfg))
		bulb.tintColor = .systemYellow
		bulb.contentMode = .scaleAspectFit
		bulb.translatesAutoresizingMaskIntoConstraints = false
		bulb.setContentHuggingPriority(.required, for: .horizontal)
		bulb.setContentCompressionResistancePriority(.required, for: .horizontal)
		bulb.isAccessibilityElement = false

		let howLabel = UILabel()
		howLabel.text = "How to open this sheet: On the keyboard, touch and hold the date & time button until this screen appears."
		howLabel.font = .preferredFont(forTextStyle: .subheadline)
		howLabel.textColor = .label
		howLabel.numberOfLines = 0
		howLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		howLabel.isAccessibilityElement = false

		row1.addArrangedSubview(bulb)
		row1.addArrangedSubview(howLabel)

		let row2 = UIStackView()
		row2.axis = .horizontal
		row2.alignment = .center
		row2.spacing = 10

		let calCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
		let cal = UIImageView(image: UIImage(systemName: "calendar.badge.clock", withConfiguration: calCfg))
		cal.tintColor = .label
		cal.contentMode = .scaleAspectFit
		cal.translatesAutoresizingMaskIntoConstraints = false
		cal.setContentHuggingPriority(.required, for: .horizontal)
		cal.isAccessibilityElement = false

		let dotsCfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
		let dots = UIImageView(image: UIImage(systemName: "ellipsis", withConfiguration: dotsCfg))
		dots.tintColor = .secondaryLabel
		dots.contentMode = .scaleAspectFit
		dots.translatesAutoresizingMaskIntoConstraints = false
		dots.setContentHuggingPriority(.required, for: .horizontal)
		dots.isAccessibilityElement = false

		let hold = UILabel()
		hold.text = "Hold"
		hold.font = .preferredFont(forTextStyle: .caption1)
		hold.textColor = .secondaryLabel
		hold.setContentHuggingPriority(.required, for: .horizontal)
		hold.isAccessibilityElement = false

		row2.addArrangedSubview(cal)
		row2.addArrangedSubview(dots)
		row2.addArrangedSubview(hold)

		let row2Wrapper = UIView()
		row2Wrapper.translatesAutoresizingMaskIntoConstraints = false
		row2.translatesAutoresizingMaskIntoConstraints = false
		row2Wrapper.addSubview(row2)
		NSLayoutConstraint.activate([
			row2.centerXAnchor.constraint(equalTo: row2Wrapper.centerXAnchor),
			row2.topAnchor.constraint(equalTo: row2Wrapper.topAnchor),
			row2.bottomAnchor.constraint(equalTo: row2Wrapper.bottomAnchor)
		])

		outer.addArrangedSubview(row1)
		outer.addArrangedSubview(row2Wrapper)

		NSLayoutConstraint.activate([
			bulb.widthAnchor.constraint(equalToConstant: 28),
			bulb.heightAnchor.constraint(equalToConstant: 28),
			cal.widthAnchor.constraint(equalToConstant: 30),
			cal.heightAnchor.constraint(equalToConstant: 28),
			dots.widthAnchor.constraint(equalToConstant: 22),
			dots.heightAnchor.constraint(equalToConstant: 20)
		])

		let chrome = MemoTimestampHintChromeView(content: outer)
		chrome.isAccessibilityElement = true
		chrome.accessibilityTraits = .staticText
		chrome.accessibilityLabel = "How to open this sheet. On the keyboard, touch and hold the date and time button until this screen appears. Then: calendar icon, ellipsis, hold."
		return chrome
	}

	private func captionLabel(_ text: String) -> UILabel {
		let l = UILabel()
		l.text = text
		l.font = .preferredFont(forTextStyle: .caption1)
		l.textColor = .secondaryLabel
		l.textAlignment = .natural
		return l
	}

	private func syncFormatUI() {
		if !selectionIsCustom, MemoTimestampSettings.matchingPresetIndex() == nil {
			selectionIsCustom = true
		}
		formatMenuButton.menu = buildFormatMenu()
		var cfg = UIButton.Configuration.gray()
		cfg.title = formatMenuTitle()
		cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
		cfg.titleLineBreakMode = .byTruncatingTail
		cfg.titleAlignment = .leading
		if #available(iOS 16.0, *) {
			cfg.indicator = .popup
		}
		formatMenuButton.configuration = cfg

		customFieldsContainer.isHidden = !selectionIsCustom
		if selectionIsCustom {
			formatTextField.text = MemoTimestampSettings.storedFormat
			selectLocalePickerRow(for: MemoTimestampSettings.storedLocaleID)
		}
	}

	private func selectLocalePickerRow(for localeID: String) {
		let list = MemoTimestampSettings.pickerLocaleIdentifiers
		if let idx = list.firstIndex(of: localeID) {
			localePicker.selectRow(idx, inComponent: 0, animated: false)
		} else if let fb = list.firstIndex(of: MemoTimestampSettings.defaultLocaleID) {
			localePicker.selectRow(fb, inComponent: 0, animated: false)
		} else if !list.isEmpty {
			localePicker.selectRow(0, inComponent: 0, animated: false)
		}
	}

	private func formatMenuTitle() -> String {
		if selectionIsCustom { return "Custom" }
		if let i = MemoTimestampSettings.matchingPresetIndex() {
			return MemoTimestampSettings.presets[i].title
		}
		return "Custom"
	}

	private func buildFormatMenu() -> UIMenu {
		var items: [UIMenuElement] = []
		for (i, p) in MemoTimestampSettings.presets.enumerated() {
			let on = !selectionIsCustom && MemoTimestampSettings.matchingPresetIndex() == i
			items.append(
				UIAction(title: p.title, state: on ? .on : .off) { [weak self] _ in
					guard let self else { return }
					self.selectionIsCustom = false
					MemoTimestampSettings.apply(preset: p)
					self.syncFormatUI()
				}
			)
		}
		items.append(
			UIAction(title: "Custom", state: selectionIsCustom ? .on : .off) { [weak self] _ in
				guard let self else { return }
				self.selectionIsCustom = true
				self.syncFormatUI()
			}
		)
		return UIMenu(title: "", options: .singleSelection, children: items)
	}

	@objc private func boldSwitchChanged() {
		MemoTimestampSettings.timestampUseBold = boldSwitch.isOn
		applyBoldVisualState()
	}

	private func applyBoldVisualState() {
		boldIcon.tintColor = boldSwitch.isOn ? .label : .tertiaryLabel
		boldIcon.alpha = boldSwitch.isOn ? 1 : 0.55
	}

	@objc private func doneTapped() {
		if selectionIsCustom {
			let fmt = formatTextField.text ?? ""
			let trimmed = fmt.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else {
				let alert = UIAlertController(
					title: nil,
					message: "Enter a dateFormat string.",
					preferredStyle: .alert
				)
				alert.addAction(UIAlertAction(title: "OK", style: .default))
				present(alert, animated: true)
				return
			}
			let row = localePicker.selectedRow(inComponent: 0)
			let list = MemoTimestampSettings.pickerLocaleIdentifiers
			let loc = (row >= 0 && row < list.count) ? list[row] : MemoTimestampSettings.defaultLocaleID
			MemoTimestampSettings.applyCustom(format: fmt, localeID: loc)
		}
		MemoTimestampSettings.onboardingComplete = true
		dismiss(animated: true)
	}

	func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
		MemoTimestampSettings.onboardingComplete = true
	}

	// MARK: - UIPickerView

	func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

	func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
		MemoTimestampSettings.pickerLocaleIdentifiers.count
	}

	func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
		let list = MemoTimestampSettings.pickerLocaleIdentifiers
		guard row >= 0, row < list.count else { return nil }
		return list[row]
	}
}

// MARK: - ヒント行の虹色エッジ（コニックグラデーション）

private final class MemoTimestampHintChromeView: UIView {
	private let gradientHost = UIView()
	private let gradientLayer = CAGradientLayer()
	private let innerCard = UIView()

	private static let spectralCGColors: [CGColor] = [
		UIColor.systemPink.cgColor,
		UIColor.systemPurple.cgColor,
		UIColor.systemIndigo.cgColor,
		UIColor.systemBlue.cgColor,
		UIColor.systemCyan.cgColor,
		UIColor.systemMint.cgColor,
		UIColor.systemGreen.cgColor,
		UIColor.systemYellow.cgColor,
		UIColor.systemOrange.cgColor,
		UIColor.systemRed.cgColor,
		UIColor.systemPink.cgColor
	]

	init(content: UIView) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		clipsToBounds = false
		layer.cornerRadius = 14
		layer.cornerCurve = .continuous
		layer.shadowColor = UIColor.systemIndigo.cgColor
		layer.shadowOpacity = 0.42
		layer.shadowOffset = .zero
		layer.shadowRadius = 12

		gradientHost.translatesAutoresizingMaskIntoConstraints = false
		gradientHost.clipsToBounds = true
		gradientHost.layer.cornerRadius = 14
		gradientHost.layer.cornerCurve = .continuous
		gradientLayer.type = .conic
		gradientLayer.colors = Self.spectralCGColors
		gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
		gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
		gradientHost.layer.addSublayer(gradientLayer)

		innerCard.translatesAutoresizingMaskIntoConstraints = false
		innerCard.backgroundColor = .secondarySystemGroupedBackground
		innerCard.layer.cornerRadius = 11
		innerCard.layer.cornerCurve = .continuous
		innerCard.clipsToBounds = true

		content.translatesAutoresizingMaskIntoConstraints = false

		addSubview(gradientHost)
		addSubview(innerCard)
		innerCard.addSubview(content)

		let inset: CGFloat = 3
		NSLayoutConstraint.activate([
			gradientHost.topAnchor.constraint(equalTo: topAnchor),
			gradientHost.leadingAnchor.constraint(equalTo: leadingAnchor),
			gradientHost.trailingAnchor.constraint(equalTo: trailingAnchor),
			gradientHost.bottomAnchor.constraint(equalTo: bottomAnchor),

			innerCard.topAnchor.constraint(equalTo: topAnchor, constant: inset),
			innerCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
			innerCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
			innerCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),

			content.topAnchor.constraint(equalTo: innerCard.topAnchor),
			content.leadingAnchor.constraint(equalTo: innerCard.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: innerCard.trailingAnchor),
			content.bottomAnchor.constraint(equalTo: innerCard.bottomAnchor)
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	override func layoutSubviews() {
		super.layoutSubviews()
		gradientLayer.frame = gradientHost.bounds
		gradientLayer.cornerRadius = gradientHost.layer.cornerRadius
		layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window != nil {
			updateMotionAnimation()
		} else {
			gradientLayer.removeAnimation(forKey: "hintSpectralSpin")
		}
	}

	private func updateMotionAnimation() {
		gradientLayer.removeAnimation(forKey: "hintSpectralSpin")
		guard window != nil else { return }
		guard !UIAccessibility.isReduceMotionEnabled else { return }
		let spin = CABasicAnimation(keyPath: "transform.rotation.z")
		spin.fromValue = 0
		spin.toValue = CGFloat.pi * 2
		spin.duration = 14
		spin.repeatCount = .greatestFiniteMagnitude
		spin.isRemovedOnCompletion = false
		gradientLayer.add(spin, forKey: "hintSpectralSpin")
	}
}

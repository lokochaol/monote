//
//  MemoTimestampSettings.swift
//  scroll
//

import Foundation

/// キーボードアクセサリの「日時」挿入で使う書式（UserDefaults 永続化）。
enum MemoTimestampSettings {
	private enum Keys {
		static let onboarding = "memo.timestamp.onboardingComplete"
		static let format = "memo.timestamp.dateFormat"
		static let localeID = "memo.timestamp.localeIdentifier"
		static let bold = "memo.timestamp.bold"
	}

	/// 既定: `yyyy.MM.dd` + 英語の短い曜日（例: 2026.04.18 Fri）
	static let defaultFormat = "yyyy.MM.dd EEE"
	static let defaultLocaleID = "en_US_POSIX"

	struct Preset: Sendable {
		let title: String
		let format: String
		let localeID: String
	}

	static let presets: [Preset] = [
		Preset(title: "yyyy.MM.dd EEE", format: "yyyy.MM.dd EEE", localeID: "en_US_POSIX"),
		Preset(title: "yyyy-MM-dd", format: "yyyy-MM-dd", localeID: "en_US_POSIX"),
		Preset(title: "yyyy/MM/dd", format: "yyyy/MM/dd", localeID: "en_US_POSIX"),
		Preset(title: "yyyy年M月d日", format: "yyyy年M月d日", localeID: "ja_JP"),
		Preset(title: "yyyy.MM.dd HH:mm", format: "yyyy.MM.dd HH:mm", localeID: "en_US_POSIX"),
		Preset(title: "yyyy-MM-dd HH:mm:ss", format: "yyyy-MM-dd HH:mm:ss", localeID: "en_US_POSIX"),
		Preset(title: "HH:mm", format: "HH:mm", localeID: "en_US_POSIX")
	]

	/// 初回の「形式を選ぶ」UIを終えたあとは true。以降はタップで挿入・長押しで形式選択。
	static var onboardingComplete: Bool {
		get { UserDefaults.standard.bool(forKey: Keys.onboarding) }
		set { UserDefaults.standard.set(newValue, forKey: Keys.onboarding) }
	}

	/// 未設定時は true（太字で挿入が既定）。
	static var timestampUseBold: Bool {
		get {
			guard UserDefaults.standard.object(forKey: Keys.bold) != nil else { return true }
			return UserDefaults.standard.bool(forKey: Keys.bold)
		}
		set { UserDefaults.standard.set(newValue, forKey: Keys.bold) }
	}

	static var storedFormat: String {
		get {
			let v = UserDefaults.standard.string(forKey: Keys.format)?.trimmingCharacters(in: .whitespacesAndNewlines)
			return (v == nil || v!.isEmpty) ? defaultFormat : v!
		}
		set { UserDefaults.standard.set(newValue, forKey: Keys.format) }
	}

	static var storedLocaleID: String {
		get {
			let v = UserDefaults.standard.string(forKey: Keys.localeID)?.trimmingCharacters(in: .whitespacesAndNewlines)
			return (v == nil || v!.isEmpty) ? defaultLocaleID : v!
		}
		set { UserDefaults.standard.set(newValue, forKey: Keys.localeID) }
	}

	static func apply(preset: Preset) {
		storedFormat = preset.format
		storedLocaleID = preset.localeID
	}

	/// 保存中の書式・ロケールがプリセットのいずれかと一致するインデックス。一致しない場合は nil（UI ではカスタム扱い）。
	static func matchingPresetIndex() -> Int? {
		for (i, p) in presets.enumerated() where p.format == storedFormat && p.localeID == storedLocaleID {
			return i
		}
		return nil
	}

	/// `Locale.availableIdentifiers` の一意・昇順（ロケールピッカー用）。
	static let pickerLocaleIdentifiers: [String] = {
		Array(Set(Locale.availableIdentifiers)).sorted()
	}()

	static func applyCustom(format: String, localeID: String) {
		let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		storedFormat = trimmed
		let loc = localeID.trimmingCharacters(in: .whitespacesAndNewlines)
		storedLocaleID = loc.isEmpty ? defaultLocaleID : loc
	}

	static func formattedNow() -> String {
		format(Date())
	}

	static func format(_ date: Date) -> String {
		let f = DateFormatter()
		f.locale = Locale(identifier: storedLocaleID)
		f.dateFormat = storedFormat
		return f.string(from: date)
	}

}

//
//  MemoJournalPalette.swift
//  scroll
//

import SwiftUI
import UIKit

enum MemoJournalPalette {
	static let horizontalInset: CGFloat = 22

	/// コーラル・アンバー・ティール（ライト／ダークで可読）
	static func uiColor(lineIndex: Int) -> UIColor {
		let i = ((lineIndex % 3) + 3) % 3
		return UIColor { trait in
			let dark = trait.userInterfaceStyle == .dark
			switch i {
			case 0:
				return dark
					? UIColor(red: 1.0, green: 0.52, blue: 0.48, alpha: 1)
					: UIColor(red: 0.78, green: 0.28, blue: 0.26, alpha: 1)
			case 1:
				return dark
					? UIColor(red: 1.0, green: 0.78, blue: 0.38, alpha: 1)
					: UIColor(red: 0.72, green: 0.48, blue: 0.12, alpha: 1)
			default:
				return dark
					? UIColor(red: 0.45, green: 0.78, blue: 0.88, alpha: 1)
					: UIColor(red: 0.18, green: 0.48, blue: 0.58, alpha: 1)
			}
		}
	}

	static func swiftUIColor(lineIndex: Int) -> Color {
		Color(uiColor: uiColor(lineIndex: lineIndex))
	}

	/// キーボードツールバー用の 3 アクセント色
	static func formatBarUIColors() -> [UIColor] {
		(0 ..< 3).map { uiColor(lineIndex: $0) }
	}

	@ViewBuilder
	static func paperBackground() -> some View {
		Color(uiColor: UIColor { trait in
			trait.userInterfaceStyle == .dark
				? UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
				: UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
		})
		.ignoresSafeArea()
	}
}

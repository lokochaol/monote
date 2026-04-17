//
//  ContentView.swift
//  scroll
//
//  Created by 廣岡晃一 on 2026/04/13.
//

import SwiftUI
struct ContentView: View {
	@State private var count = 0
	var body: some View {
		NavigationStack {
			VStack(spacing: 16) {
				Text("カウント: \(count)")
					.font(.title2)
				Button("増やす") {
					count += 1
				}
				.buttonStyle(.borderedProminent)
			}
			.padding()
			.navigationTitle("はじめてのSwiftUI")
		}
	}
}

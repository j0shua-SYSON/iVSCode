/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import SwiftUI

struct RootView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		ZStack {
			Color(red: 0.07, green: 0.08, blue: 0.10)
				.ignoresSafeArea()

			switch model.phase {
			case .starting(let message):
				BootView(message: message)
			case .ready(let url):
				WorkbenchView(
					url: url,
					messageHandler: model.receiveWorkbenchMessage,
					navigationFailureHandler: model.workbenchNavigationFailed,
					navigationFinishedHandler: model.workbenchNavigationFinished
				)
					.ignoresSafeArea()
				if !model.workbenchStarted {
					BootView(message: "Loading the Code - OSS workbench")
						.allowsHitTesting(false)
				}
			case .failed(let message):
				FailureView(message: message, retry: model.start)
			}
		}
	}
}
private struct BootView: View {
	let message: String
	@State private var cursorVisible = true

	var body: some View {
		VStack(alignment: .leading, spacing: 24) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Text(">_")
					.foregroundStyle(Color(red: 0.30, green: 0.64, blue: 1.0))
			Text("iVSCode")
					.foregroundStyle(.white)
			}
			.font(.system(size: 32, weight: .semibold, design: .monospaced))

			VStack(alignment: .leading, spacing: 8) {
				Text("LOCAL / PRIVATE / READY")
					.font(.system(size: 11, weight: .semibold, design: .monospaced))
					.tracking(1.4)
					.foregroundStyle(.secondary)

				HStack(spacing: 0) {
					Text(message)
					Text(cursorVisible ? "▋" : " ")
						.foregroundStyle(Color(red: 0.30, green: 0.64, blue: 1.0))
				}
				.font(.system(size: 14, weight: .regular, design: .monospaced))
				.foregroundStyle(.white.opacity(0.82))
			}
		}
		.frame(maxWidth: 520, alignment: .leading)
		.padding(32)
		.task {
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(520))
				withAnimation(.linear(duration: 0.08)) {
					cursorVisible.toggle()
				}
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel("iVSCode is starting. \(message)")
	}
}

private struct FailureView: View {
	let message: String
	let retry: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Text("iVSCode could not start")
				.font(.title2.weight(.semibold))
				.foregroundStyle(.white)
			Text(message)
				.font(.body.monospaced())
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
			Button("Try Again", action: retry)
				.buttonStyle(.borderedProminent)
		}
		.frame(maxWidth: 560, alignment: .leading)
		.padding(32)
	}
}

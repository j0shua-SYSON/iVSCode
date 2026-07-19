/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import SwiftUI
import UIKit
import WebKit

struct WorkbenchView: UIViewRepresentable {
	let url: URL
	let messageHandler: (Any) -> Void
	let navigationFailureHandler: (String) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(
			baseURL: url,
			messageHandler: messageHandler,
			navigationFailureHandler: navigationFailureHandler
		)
	}

	func makeUIView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .default()
		configuration.allowsInlineMediaPlayback = true
		configuration.mediaTypesRequiringUserActionForPlayback = []
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		configuration.defaultWebpagePreferences.preferredContentMode = .mobile
		configuration.applicationNameForUserAgent = "iVSCode/0.1"
		configuration.userContentController.add(context.coordinator, name: "ivscode")

		let webView = WKWebView(frame: .zero, configuration: configuration)
		webView.navigationDelegate = context.coordinator
		webView.uiDelegate = context.coordinator
		webView.scrollView.contentInsetAdjustmentBehavior = .never
		webView.scrollView.keyboardDismissMode = .none
		webView.scrollView.bounces = false
		webView.allowsLinkPreview = false
		webView.isOpaque = true
		webView.backgroundColor = UIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)
#if DEBUG
		webView.isInspectable = true
#endif
		webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
		return webView
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		guard webView.url?.host != url.host || webView.url?.port != url.port else {
			return
		}
		context.coordinator.baseURL = url
		webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
	}

	static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
		webView.configuration.userContentController.removeScriptMessageHandler(forName: "ivscode")
		webView.stopLoading()
	}

	final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
		var baseURL: URL
		private let messageHandler: (Any) -> Void
		private let navigationFailureHandler: (String) -> Void

		init(
			baseURL: URL,
			messageHandler: @escaping (Any) -> Void,
			navigationFailureHandler: @escaping (String) -> Void
		) {
			self.baseURL = baseURL
			self.messageHandler = messageHandler
			self.navigationFailureHandler = navigationFailureHandler
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			messageHandler(message.body)
		}

		func webView(
			_ webView: WKWebView,
			decidePolicyFor navigationAction: WKNavigationAction,
			decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
		) {
			guard let target = navigationAction.request.url else {
				decisionHandler(.cancel)
				return
			}
			if isLocal(target) {
				decisionHandler(.allow)
				return
			}
			if target.scheme == "about" || target.scheme == "blob" || target.scheme == "data" {
				decisionHandler(.allow)
				return
			}
			decisionHandler(.cancel)
			Task { @MainActor in
				await UIApplication.shared.open(target)
			}
		}

		func webView(
			_ webView: WKWebView,
			createWebViewWith configuration: WKWebViewConfiguration,
			for navigationAction: WKNavigationAction,
			windowFeatures: WKWindowFeatures
		) -> WKWebView? {
			guard let target = navigationAction.request.url else {
				return nil
			}
			if isLocal(target) {
				webView.load(URLRequest(url: target))
			} else {
				Task { @MainActor in
					await UIApplication.shared.open(target)
				}
			}
			return nil
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
			navigationFailureHandler("The iVSCode workbench stopped loading: \(error.localizedDescription)")
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
			navigationFailureHandler("The private workbench origin is unavailable: \(error.localizedDescription)")
		}

		func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
			webView.reload()
		}

		private func isLocal(_ url: URL) -> Bool {
			guard url.scheme == baseURL.scheme, url.port == baseURL.port else {
				return false
			}
			if url.host == baseURL.host {
				return true
			}
			return url.host == "localhost" || url.host?.hasSuffix(".localhost") == true
		}
	}
}

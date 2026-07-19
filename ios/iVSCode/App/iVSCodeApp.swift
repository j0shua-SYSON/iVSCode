/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import SwiftUI

@main
struct iVSCodeApp: App {
	@Environment(\.scenePhase) private var scenePhase
	@StateObject private var model = AppModel()

	var body: some Scene {
		WindowGroup {
			RootView(model: model)
				.preferredColorScheme(.dark)
				.onChange(of: scenePhase) { _, phase in
					if phase == .active {
						model.resumeIfNeeded()
					}
				}
		}
	}
}

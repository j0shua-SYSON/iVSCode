/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { create, URI } from './out/vs/workbench/workbench.web.main.internal.js';

const workspace = { folderUri: URI.from({ scheme: 'code-mobile', path: '/workspace' }) };

const workspaceProvider = {
	workspace,
	trusted: true,
	async open(target, options) {
		if (target?.folderUri?.scheme === 'code-mobile') {
			const url = new URL(window.location.href);
			url.searchParams.set('folder', target.folderUri.toString(true));
			if (options?.reuse !== false) {
				window.location.replace(url);
				return true;
			}
		}
		return false;
	},
	hasRemote() {
		return false;
	}
};

create(document.body, {
	workspaceProvider,
	webviewEndpoint: `http://{{uuid}}.localhost:${window.location.port}/out/vs/workbench/contrib/webview/browser/pre/`,
	enableWorkspaceTrust: true,
	configurationDefaults: {
		'window.menuBarVisibility': 'hidden',
		'window.commandCenter': false,
		'workbench.startupEditor': 'none',
		'workbench.layoutControl.enabled': false,
		'workbench.activityBar.location': 'default',
		'workbench.editor.showTabs': 'multiple',
		'editor.accessibilityPageSize': 20,
		'terminal.integrated.gpuAcceleration': 'off'
	},
	productConfiguration: {
		nameShort: 'iVSCode',
		nameLong: 'iVSCode',
		applicationName: 'ivscode',
		dataFolderName: '.ivscode',
		urlProtocol: 'ivscode',
		enableTelemetry: false
	},
	windowIndicator: {
		label: 'iVSCode',
		tooltip: 'On-device workspace'
	}
});

const reportWorkbenchStarted = () => {
	if (document.querySelector('.monaco-workbench')) {
		window.webkit?.messageHandlers?.ivscode?.postMessage({ type: 'workbenchStarted' });
		return;
	}
	window.requestAnimationFrame(reportWorkbenchStarted);
};
reportWorkbenchStarted();

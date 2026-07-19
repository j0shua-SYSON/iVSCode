/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

#import <Foundation/Foundation.h>
@import QEMUKitInternal;

NS_ASSUME_NONNULL_BEGIN

/// Starts UTM's interpreter-only QEMU framework inside the iOS application.
///
/// QEMU is process-global. Create at most one launcher during the lifetime of
/// the application and stop it through QMP before releasing this object.
@interface IVQemuLauncher : NSObject <QEMULauncher>

@property (class, nonatomic, readonly, getter=isProcessAvailable) BOOL processAvailable;
@property (nonatomic, weak) id<QEMULauncherDelegate> launcherDelegate;
@property (nonatomic, strong, nullable) QEMULogging *logging;
@property (atomic, readonly, getter=isRunning) BOOL running;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments
				   environment:(NSDictionary<NSString *, NSString *> *)environment NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

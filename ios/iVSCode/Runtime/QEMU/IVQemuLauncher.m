/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

#import "IVQemuLauncher.h"

#import <dlfcn.h>
#import <pthread.h>
#import <stdlib.h>

static NSString *const IVQemuLauncherErrorDomain = @"dev.ivscode.runtime.qemu";
static BOOL IVQemuProcessClaimed = NO;

typedef int (*IVQemuInit)(int argc, const char * _Nonnull argv[], const char * _Nonnull envp[]);
typedef void (*IVQemuMainLoop)(void);
typedef void (*IVQemuCleanup)(void);

@interface IVQemuLauncher ()

@property (nonatomic, copy) NSArray<NSString *> *arguments;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, strong) dispatch_semaphore_t finished;
@property (atomic, readwrite, getter=isRunning) BOOL running;
@property (atomic) NSInteger exitCode;
@property (nonatomic, copy) NSDictionary<NSString *, id> *previousEnvironment;

@end


@implementation IVQemuLauncher {
	void *_libraryHandle;
	IVQemuInit _qemuInit;
	IVQemuMainLoop _qemuMainLoop;
	IVQemuCleanup _qemuCleanup;
}

+ (BOOL)isProcessAvailable {
	@synchronized ([IVQemuLauncher class]) {
		return !IVQemuProcessClaimed;
	}
}

- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments
				   environment:(NSDictionary<NSString *,NSString *> *)environment {
	self = [super init];
	if (self) {
		_arguments = [arguments copy];
		_environment = [environment copy];
		dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
			DISPATCH_QUEUE_SERIAL,
			QOS_CLASS_UTILITY,
			QOS_MIN_RELATIVE_PRIORITY
		);
		_completionQueue = dispatch_queue_create("dev.ivscode.qemu.completion", attributes);
	}
	return self;
}

- (NSError *)errorWithMessage:(NSString *)message {
	return [NSError errorWithDomain:IVQemuLauncherErrorDomain
							 code:1
						 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL IVClaimQemuProcess(void) {
	@synchronized ([IVQemuLauncher class]) {
		if (IVQemuProcessClaimed) {
			return NO;
		}
		IVQemuProcessClaimed = YES;
		return YES;
	}
}

static void IVReleaseQemuProcess(void) {
	@synchronized ([IVQemuLauncher class]) {
		IVQemuProcessClaimed = NO;
	}
}

- (void)captureEnvironment {
	NSMutableDictionary<NSString *, id> *previous = [NSMutableDictionary dictionary];
	for (NSString *key in self.environment) {
		const char *value = getenv(key.UTF8String);
		previous[key] = value ? [NSString stringWithUTF8String:value] : NSNull.null;
	}
	self.previousEnvironment = previous;
}

- (void)restoreEnvironment {
	[self.previousEnvironment enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
		if (value == NSNull.null) {
			unsetenv(key.UTF8String);
		} else {
			setenv(key.UTF8String, [(NSString *)value UTF8String], 1);
		}
	}];
	self.previousEnvironment = @{};
}

- (NSURL *)qemuBinaryURL {
	NSURL *frameworks = NSBundle.mainBundle.privateFrameworksURL;
	return [[frameworks URLByAppendingPathComponent:@"qemu-aarch64-softmmu.framework" isDirectory:YES]
		URLByAppendingPathComponent:@"qemu-aarch64-softmmu" isDirectory:NO];
}

- (BOOL)loadQemu:(NSError * _Nullable * _Nullable)error {
	NSURL *binary = self.qemuBinaryURL;
	if (![NSFileManager.defaultManager isExecutableFileAtPath:binary.path]) {
		if (error) {
			*error = [self errorWithMessage:@"The bundled ARM64 QEMU engine is missing."];
		}
		return NO;
	}

	_libraryHandle = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
	if (!_libraryHandle) {
		if (error) {
			const char *detail = dlerror();
			NSString *message = detail ? [NSString stringWithUTF8String:detail] : @"Unknown dynamic loader error.";
			*error = [self errorWithMessage:message];
		}
		return NO;
	}

	_qemuInit = (IVQemuInit)dlsym(_libraryHandle, "qemu_init");
	_qemuMainLoop = (IVQemuMainLoop)dlsym(_libraryHandle, "qemu_main_loop");
	_qemuCleanup = (IVQemuCleanup)dlsym(_libraryHandle, "qemu_cleanup");
	if (!_qemuInit || !_qemuMainLoop || !_qemuCleanup) {
		if (error) {
			*error = [self errorWithMessage:@"The QEMU engine does not export the reviewed launcher contract."];
		}
		dlclose(_libraryHandle);
		_libraryHandle = NULL;
		return NO;
	}
	return YES;
}

static void IVFreeStrings(char **strings, NSUInteger count) {
	if (!strings) {
		return;
	}
	for (NSUInteger index = 0; index < count; index++) {
		free(strings[index]);
	}
	free(strings);
}

static void *IVRunQemu(void *context) {
	@autoreleasepool {
		IVQemuLauncher *launcher = (__bridge_transfer IVQemuLauncher *)context;
		NSArray<NSString *> *arguments = launcher.arguments;
		NSDictionary<NSString *, NSString *> *environment = launcher.environment;

		NSUInteger argumentCount = arguments.count + 1;
		char **argv = calloc(argumentCount + 1, sizeof(char *));
		argv[0] = strdup("qemu-aarch64-softmmu");
		for (NSUInteger index = 0; index < arguments.count; index++) {
			argv[index + 1] = strdup(arguments[index].UTF8String);
		}

		NSUInteger environmentCount = environment.count;
		char **envp = calloc(environmentCount + 1, sizeof(char *));
		__block NSUInteger environmentIndex = 0;
		[environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
			NSString *entry = [NSString stringWithFormat:@"%@=%@", key, value];
			envp[environmentIndex++] = strdup(entry.UTF8String);
			setenv(key.UTF8String, value.UTF8String, 1);
		}];

		int result = launcher->_qemuInit((int)argumentCount, (const char **)argv, (const char **)envp);
		if (result == 0) {
			launcher->_qemuMainLoop();
			launcher->_qemuCleanup();
		}
		launcher.exitCode = result;
		IVFreeStrings(argv, argumentCount);
		IVFreeStrings(envp, environmentCount);
		dispatch_semaphore_signal(launcher.finished);
	}
	return NULL;
}

- (void)startQemuWithCompletion:(void (^)(NSError * _Nullable))completion {
	@synchronized (self) {
		if (self.running) {
			completion([self errorWithMessage:@"The in-process QEMU engine is already running."]);
			return;
		}
		if (!IVClaimQemuProcess()) {
			completion([self errorWithMessage:@"An earlier in-process QEMU engine has not stopped safely."]);
			return;
		}

		NSError *loadError = nil;
		if (![self loadQemu:&loadError]) {
			IVReleaseQemuProcess();
			completion(loadError);
			return;
		}

		self.finished = dispatch_semaphore_create(0);
		self.exitCode = -1;
		self.running = YES;

		__block pthread_t qemuThread = (pthread_t)NULL;
		__weak IVQemuLauncher *weakSelf = self;
		if (atexit_b(^{
			if (pthread_equal(pthread_self(), qemuThread)) {
				IVQemuLauncher *strongSelf = weakSelf;
				if (strongSelf) {
					strongSelf.exitCode = -1;
					dispatch_semaphore_signal(strongSelf.finished);
				}
				pthread_exit(NULL);
			}
		}) != 0) {
			self.running = NO;
			dlclose(_libraryHandle);
			_libraryHandle = NULL;
			IVReleaseQemuProcess();
			completion([self errorWithMessage:@"The QEMU exit guard could not be installed."]);
			return;
		}

		[self captureEnvironment];
		pthread_attr_t attributes;
		pthread_attr_init(&attributes);
		pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
		void *threadContext = (__bridge_retained void *)self;
		int createResult = pthread_create(
			&qemuThread,
			&attributes,
			IVRunQemu,
			threadContext
		);
		pthread_attr_destroy(&attributes);
		if (createResult != 0) {
			CFBridgingRelease(threadContext);
			[self restoreEnvironment];
			self.running = NO;
			dlclose(_libraryHandle);
			_libraryHandle = NULL;
			IVReleaseQemuProcess();
			completion([self errorWithMessage:@"The dedicated QEMU thread could not be created."]);
			return;
		}

		dispatch_async(self.completionQueue, ^{
			dispatch_semaphore_wait(self.finished, DISPATCH_TIME_FOREVER);
			pthread_join(qemuThread, NULL);
			NSInteger exitCode = self.exitCode;
			if (self->_libraryHandle) {
				dlclose(self->_libraryHandle);
				self->_libraryHandle = NULL;
			}
			[self restoreEnvironment];
			IVReleaseQemuProcess();
			self.running = NO;
			dispatch_async(dispatch_get_main_queue(), ^{
				NSString *message = exitCode == 0 ? nil : @"The in-process QEMU engine exited unexpectedly.";
				[self.launcherDelegate qemuLauncher:self didExitWithExitCode:exitCode message:message];
			});
		});

		completion(nil);
	}
}

- (void)stopQemu {
	// QEMU has no safe cross-thread cancellation primitive. The owner must send
	// QMP powerdown/quit; this mirrors pinned UTM's iOS stopProcess behaviour.
}

@end

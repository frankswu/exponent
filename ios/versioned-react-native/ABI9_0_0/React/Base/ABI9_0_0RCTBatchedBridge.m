/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

#import "ABI9_0_0RCTAssert.h"
#import "ABI9_0_0RCTBridge.h"
#import "ABI9_0_0RCTBridge+Private.h"
#import "ABI9_0_0RCTBridgeMethod.h"
#import "ABI9_0_0RCTConvert.h"
#import "ABI9_0_0RCTDisplayLink.h"
#import "ABI9_0_0RCTJSCExecutor.h"
#import "ABI9_0_0RCTJavaScriptLoader.h"
#import "ABI9_0_0RCTLog.h"
#import "ABI9_0_0RCTModuleData.h"
#import "ABI9_0_0RCTPerformanceLogger.h"
#import "ABI9_0_0RCTProfile.h"
#import "ABI9_0_0RCTSourceCode.h"
#import "ABI9_0_0RCTUtils.h"
#import "ABI9_0_0RCTRedBox.h"

#define ABI9_0_0RCTAssertJSThread() \
  ABI9_0_0RCTAssert(![NSStringFromClass([self->_javaScriptExecutor class]) isEqualToString:@"ABI9_0_0RCTJSCExecutor"] || \
              [[[NSThread currentThread] name] isEqualToString:ABI9_0_0RCTJSCThreadName], \
            @"This method must be called on JS thread")

/**
 * Must be kept in sync with `MessageQueue.js`.
 */
typedef NS_ENUM(NSUInteger, ABI9_0_0RCTBridgeFields) {
  ABI9_0_0RCTBridgeFieldRequestModuleIDs = 0,
  ABI9_0_0RCTBridgeFieldMethodIDs,
  ABI9_0_0RCTBridgeFieldParams,
  ABI9_0_0RCTBridgeFieldCallID,
};

ABI9_0_0RCT_EXTERN NSArray<Class> *ABI9_0_0RCTGetModuleClasses(void);

@implementation ABI9_0_0RCTBatchedBridge
{
  BOOL _wasBatchActive;
  NSMutableArray<dispatch_block_t> *_pendingCalls;
  NSMutableDictionary<NSString *, ABI9_0_0RCTModuleData *> *_moduleDataByName;
  NSArray<ABI9_0_0RCTModuleData *> *_moduleDataByID;
  NSArray<Class> *_moduleClassesByID;
  ABI9_0_0RCTDisplayLink *_displayLink;
}

@synthesize flowID = _flowID;
@synthesize flowIDMap = _flowIDMap;
@synthesize flowIDMapLock = _flowIDMapLock;
@synthesize loading = _loading;
@synthesize valid = _valid;

- (instancetype)initWithParentBridge:(ABI9_0_0RCTBridge *)bridge
{
  ABI9_0_0RCTAssertParam(bridge);

  if (self = [super initWithDelegate:bridge.delegate
                           bundleURL:bridge.bundleURL
                      moduleProvider:bridge.moduleProvider
                       launchOptions:bridge.launchOptions]) {
    _parentBridge = bridge;

    /**
     * Set Initial State
     */
    _valid = YES;
    _loading = YES;
    _pendingCalls = [NSMutableArray new];
    _displayLink = [ABI9_0_0RCTDisplayLink new];

    [ABI9_0_0RCTBridge setCurrentBridge:self];

    [[NSNotificationCenter defaultCenter]
     postNotificationName:ABI9_0_0RCTJavaScriptWillStartLoadingNotification
     object:_parentBridge userInfo:@{@"bridge": self}];

    [self start];
  }
  return self;
}

ABI9_0_0RCT_NOT_IMPLEMENTED(- (instancetype)initWithDelegate:(id<ABI9_0_0RCTBridgeDelegate>)delegate
                                           bundleURL:(NSURL *)bundleURL
                                      moduleProvider:(ABI9_0_0RCTBridgeModuleProviderBlock)block
                                       launchOptions:(NSDictionary *)launchOptions)

- (void)start
{
  dispatch_queue_t bridgeQueue = dispatch_queue_create("com.facebook.ReactABI9_0_0.ABI9_0_0RCTBridgeQueue", DISPATCH_QUEUE_CONCURRENT);

  dispatch_group_t initModulesAndLoadSource = dispatch_group_create();

  // Asynchronously load source code
  dispatch_group_enter(initModulesAndLoadSource);
  __weak ABI9_0_0RCTBatchedBridge *weakSelf = self;
  __block NSData *sourceCode;
  [self loadSource:^(NSError *error, NSData *source, __unused int64_t sourceLength) {
    if (error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopLoadingWithError:error];
      });
    }

    sourceCode = source;
    dispatch_group_leave(initModulesAndLoadSource);
  }];

  // Synchronously initialize all native modules that cannot be loaded lazily
  [self initModulesWithDispatchGroup:initModulesAndLoadSource];

  ABI9_0_0RCTPerformanceLogger *performanceLogger = self->_performanceLogger;
  __block NSString *config;
  dispatch_group_enter(initModulesAndLoadSource);
  dispatch_async(bridgeQueue, ^{
    dispatch_group_t setupJSExecutorAndModuleConfig = dispatch_group_create();

    // Asynchronously initialize the JS executor
    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      [performanceLogger markStartForTag:ABI9_0_0RCTPLJSCExecutorSetup];
      [weakSelf setUpExecutor];
      [performanceLogger markStopForTag:ABI9_0_0RCTPLJSCExecutorSetup];
    });

    // Asynchronously gather the module config
    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      if (weakSelf.valid) {
        [performanceLogger markStartForTag:ABI9_0_0RCTPLNativeModulePrepareConfig];
        config = [weakSelf moduleConfig];
        [performanceLogger markStopForTag:ABI9_0_0RCTPLNativeModulePrepareConfig];
      }
    });

    dispatch_group_notify(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      // We're not waiting for this to complete to leave dispatch group, since
      // injectJSONConfiguration and executeSourceCode will schedule operations
      // on the same queue anyway.
      [performanceLogger markStartForTag:ABI9_0_0RCTPLNativeModuleInjectConfig];
      [weakSelf injectJSONConfiguration:config onComplete:^(NSError *error) {
        [performanceLogger markStopForTag:ABI9_0_0RCTPLNativeModuleInjectConfig];
        if (error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stopLoadingWithError:error];
          });
        }
      }];
      dispatch_group_leave(initModulesAndLoadSource);
    });
  });

  dispatch_group_notify(initModulesAndLoadSource, bridgeQueue, ^{
    ABI9_0_0RCTBatchedBridge *strongSelf = weakSelf;
    if (sourceCode && strongSelf.loading) {
      [strongSelf executeSourceCode:sourceCode];
    }
  });
}

- (void)loadSource:(ABI9_0_0RCTSourceLoadBlock)_onSourceLoad
{
  [_performanceLogger markStartForTag:ABI9_0_0RCTPLScriptDownload];

  ABI9_0_0RCTPerformanceLogger *performanceLogger = _performanceLogger;
  ABI9_0_0RCTSourceLoadBlock onSourceLoad = ^(NSError *error, NSData *source, int64_t sourceLength) {
    [performanceLogger markStopForTag:ABI9_0_0RCTPLScriptDownload];
    [performanceLogger setValue:sourceLength forTag:ABI9_0_0RCTPLBundleSize];
    _onSourceLoad(error, source, sourceLength);
  };

  if ([self.delegate respondsToSelector:@selector(loadSourceForBridge:withBlock:)]) {
    [self.delegate loadSourceForBridge:_parentBridge withBlock:onSourceLoad];
  } else {
    ABI9_0_0RCTAssert(self.bundleURL, @"bundleURL must be non-nil when not implementing loadSourceForBridge");

    [ABI9_0_0RCTJavaScriptLoader loadBundleAtURL:self.bundleURL onComplete:^(NSError *error, NSData *source, int64_t sourceLength) {
      if (error && [self.delegate respondsToSelector:@selector(fallbackSourceURLForBridge:)]) {
        NSURL *fallbackURL = [self.delegate fallbackSourceURLForBridge:self->_parentBridge];
        if (fallbackURL && ![fallbackURL isEqual:self.bundleURL]) {
          ABI9_0_0RCTLogError(@"Failed to load bundle(%@) with error:(%@)", self.bundleURL, error.localizedDescription);
          self.bundleURL = fallbackURL;
          [ABI9_0_0RCTJavaScriptLoader loadBundleAtURL:self.bundleURL onComplete:onSourceLoad];
          return;
        }
      }
      onSourceLoad(error, source, sourceLength);
    }];
  }
}

- (NSArray<Class> *)moduleClasses
{
  if (ABI9_0_0RCT_DEBUG && _valid && _moduleClassesByID == nil) {
    ABI9_0_0RCTLogError(@"Bridge modules have not yet been initialized. You may be "
                "trying to access a module too early in the startup procedure.");
  }
  return _moduleClassesByID;
}

/**
 * Used by ABI9_0_0RCTUIManager
 */
- (ABI9_0_0RCTModuleData *)moduleDataForName:(NSString *)moduleName
{
  return _moduleDataByName[moduleName];
}

- (id)moduleForName:(NSString *)moduleName
{
  return _moduleDataByName[moduleName].instance;
}

- (BOOL)moduleIsInitialized:(Class)moduleClass
{
  return _moduleDataByName[ABI9_0_0RCTBridgeModuleNameForClass(moduleClass)].hasInstance;
}

- (NSArray *)configForModuleName:(NSString *)moduleName
{
  ABI9_0_0RCTModuleData *moduleData = _moduleDataByName[moduleName];
  if (!moduleData) {
    moduleData = _moduleDataByName[[@"RCT" stringByAppendingString:moduleName]];
  }
  if (moduleData) {
    return moduleData.config;
  }
  return (id)kCFNull;
}

- (void)initModulesWithDispatchGroup:(dispatch_group_t)dispatchGroup
{
  [_performanceLogger markStartForTag:ABI9_0_0RCTPLNativeModuleInit];

  NSArray<id<ABI9_0_0RCTBridgeModule>> *extraModules = nil;
  if (self.delegate) {
    if ([self.delegate respondsToSelector:@selector(extraModulesForBridge:)]) {
      extraModules = [self.delegate extraModulesForBridge:_parentBridge];
    }
  } else if (self.moduleProvider) {
    extraModules = self.moduleProvider();
  }

  if (ABI9_0_0RCT_DEBUG && !ABI9_0_0RCTRunningInTestEnvironment()) {

    // Check for unexported modules
    static Class *classes;
    static unsigned int classCount;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      classes = objc_copyClassList(&classCount);
    });

    NSMutableSet *moduleClasses = [NSMutableSet new];
    [moduleClasses addObjectsFromArray:ABI9_0_0RCTGetModuleClasses()];
    [moduleClasses addObjectsFromArray:[extraModules valueForKeyPath:@"class"]];

    for (unsigned int i = 0; i < classCount; i++)
    {
      Class cls = classes[i];
      Class superclass = cls;
      while (superclass)
      {
        if (class_conformsToProtocol(superclass, @protocol(ABI9_0_0RCTBridgeModule)))
        {
          if (![moduleClasses containsObject:cls] &&
              ![cls respondsToSelector:@selector(moduleName)]) {
            ABI9_0_0RCTLogWarn(@"Class %@ was not exported. Did you forget to use "
                       "ABI9_0_0RCT_EXPORT_MODULE()?", cls);
          }
          break;
        }
        superclass = class_getSuperclass(superclass);
      }
    }
  }

  NSMutableArray<Class> *moduleClassesByID = [NSMutableArray new];
  NSMutableArray<ABI9_0_0RCTModuleData *> *moduleDataByID = [NSMutableArray new];
  NSMutableDictionary<NSString *, ABI9_0_0RCTModuleData *> *moduleDataByName = [NSMutableDictionary new];

  // Set up moduleData for pre-initialized module instances
  for (id<ABI9_0_0RCTBridgeModule> module in extraModules) {
    Class moduleClass = [module class];
    NSString *moduleName = ABI9_0_0RCTBridgeModuleNameForClass(moduleClass);

    if (ABI9_0_0RCT_DEBUG) {
      // Check for name collisions between preregistered modules
      ABI9_0_0RCTModuleData *moduleData = moduleDataByName[moduleName];
      if (moduleData) {
        ABI9_0_0RCTLogError(@"Attempted to register ABI9_0_0RCTBridgeModule class %@ for the "
                    "name '%@', but name was already registered by class %@",
                    moduleClass, moduleName, moduleData.moduleClass);
        continue;
      }
    }

    // Instantiate moduleData container
    ABI9_0_0RCTModuleData *moduleData = [[ABI9_0_0RCTModuleData alloc] initWithModuleInstance:module
                                                                       bridge:self];
    moduleDataByName[moduleName] = moduleData;
    [moduleClassesByID addObject:moduleClass];
    [moduleDataByID addObject:moduleData];

    // Set executor instance
    if (moduleClass == self.executorClass) {
      _javaScriptExecutor = (id<ABI9_0_0RCTJavaScriptExecutor>)module;
    }
  }

  // The executor is a bridge module, but we want it to be instantiated before
  // any other module has access to the bridge, in case they need the JS thread.
  // TODO: once we have more fine-grained control of init (t11106126) we can
  // probably just replace this with [self moduleForClass:self.executorClass]
  if (!_javaScriptExecutor) {
    id<ABI9_0_0RCTJavaScriptExecutor> executorModule = [self.executorClass new];
    ABI9_0_0RCTModuleData *moduleData = [[ABI9_0_0RCTModuleData alloc] initWithModuleInstance:executorModule
                                                                       bridge:self];
    moduleDataByName[moduleData.name] = moduleData;
    [moduleClassesByID addObject:self.executorClass];
    [moduleDataByID addObject:moduleData];

    // NOTE: _javaScriptExecutor is a weak reference
    _javaScriptExecutor = executorModule;
  }

  // Set up moduleData for automatically-exported modules
  for (Class moduleClass in ABI9_0_0RCTGetModuleClasses()) {
    NSString *moduleName = ABI9_0_0RCTBridgeModuleNameForClass(moduleClass);

    // Check for module name collisions
    ABI9_0_0RCTModuleData *moduleData = moduleDataByName[moduleName];
    if (moduleData) {
      if (moduleData.hasInstance) {
        // Existing module was preregistered, so it takes precedence
        continue;
      } else if ([moduleClass new] == nil) {
        // The new module returned nil from init, so use the old module
        continue;
      } else if ([moduleData.moduleClass new] != nil) {
        // Both modules were non-nil, so it's unclear which should take precedence
        ABI9_0_0RCTLogError(@"Attempted to register ABI9_0_0RCTBridgeModule class %@ for the "
                    "name '%@', but name was already registered by class %@",
                    moduleClass, moduleName, moduleData.moduleClass);
      }
    }

    // Instantiate moduleData (TODO: can we defer this until config generation?)
    moduleData = [[ABI9_0_0RCTModuleData alloc] initWithModuleClass:moduleClass
                                                     bridge:self];
    moduleDataByName[moduleName] = moduleData;
    [moduleClassesByID addObject:moduleClass];
    [moduleDataByID addObject:moduleData];
  }

  // Store modules
  _moduleDataByID = [moduleDataByID copy];
  _moduleDataByName = [moduleDataByName copy];
  _moduleClassesByID = [moduleClassesByID copy];

  // Synchronously set up the pre-initialized modules
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.hasInstance &&
        (!moduleData.requiresMainQueueSetup || ABI9_0_0RCTIsMainQueue())) {
      // Modules that were pre-initialized should ideally be set up before
      // bridge init has finished, otherwise the caller may try to access the
      // module directly rather than via `[bridge moduleForClass:]`, which won't
      // trigger the lazy initialization process. If the module cannot safely be
      // set up on the current thread, it will instead be async dispatched
      // to the main thread to be set up in the loop below.
      (void)[moduleData instance];
    }
  }

  // From this point on, ABI9_0_0RCTDidInitializeModuleNotification notifications will
  // be sent the first time a module is accessed.
  _moduleSetupComplete = YES;

  // Set up modules that require main thread init or constants export
  [_performanceLogger setValue:0 forTag:ABI9_0_0RCTPLNativeModuleMainThread];
  NSUInteger modulesOnMainQueueCount = 0;
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    __weak ABI9_0_0RCTBatchedBridge *weakSelf = self;
    if (moduleData.requiresMainQueueSetup || moduleData.hasConstantsToExport) {
      // Modules that need to be set up on the main thread cannot be initialized
      // lazily when required without doing a dispatch_sync to the main thread,
      // which can result in deadlock. To avoid this, we initialize all of these
      // modules on the main thread in parallel with loading the JS code, so
      // they will already be available before they are ever required.
      dispatch_group_async(dispatchGroup, dispatch_get_main_queue(), ^{
        ABI9_0_0RCTBatchedBridge *strongSelf = weakSelf;
        if (!strongSelf.valid) {
          return;
        }

        [strongSelf->_performanceLogger appendStartForTag:ABI9_0_0RCTPLNativeModuleMainThread];
        (void)[moduleData instance];
        [moduleData gatherConstants];
        [strongSelf->_performanceLogger appendStopForTag:ABI9_0_0RCTPLNativeModuleMainThread];
      });
      modulesOnMainQueueCount++;
    }
  }

  [_performanceLogger markStopForTag:ABI9_0_0RCTPLNativeModuleInit];
  [_performanceLogger setValue:modulesOnMainQueueCount forTag:ABI9_0_0RCTPLNativeModuleMainThreadUsesCount];
}

- (void)setUpExecutor
{
  [_javaScriptExecutor setUp];
}

- (void)registerModuleForFrameUpdates:(id<ABI9_0_0RCTBridgeModule>)module
                       withModuleData:(ABI9_0_0RCTModuleData *)moduleData
{
  [_displayLink registerModuleForFrameUpdates:module withModuleData:moduleData];
}

- (NSString *)moduleConfig
{
  NSMutableArray<NSArray *> *config = [NSMutableArray new];
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (self.executorClass == [ABI9_0_0RCTJSCExecutor class]) {
      [config addObject:@[moduleData.name]];
    } else {
      [config addObject:ABI9_0_0RCTNullIfNil(moduleData.config)];
    }
  }

  return ABI9_0_0RCTJSONStringify(@{
    @"remoteModuleConfig": config,
  }, NULL);
}

- (void)injectJSONConfiguration:(NSString *)configJSON
                     onComplete:(void (^)(NSError *))onComplete
{
  if (!_valid) {
    return;
  }

  [_javaScriptExecutor injectJSONText:configJSON
                  asGlobalObjectNamed:@"__fbBatchedBridgeConfig"
                             callback:onComplete];
}

- (void)executeSourceCode:(NSData *)sourceCode
{
  if (!_valid || !_javaScriptExecutor) {
    return;
  }

  ABI9_0_0RCTSourceCode *sourceCodeModule = [self moduleForClass:[ABI9_0_0RCTSourceCode class]];
  sourceCodeModule.scriptURL = self.bundleURL;

  [self enqueueApplicationScript:sourceCode url:self.bundleURL onComplete:^(NSError *loadError) {
    if (!self->_valid) {
      return;
    }

    if (loadError) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self stopLoadingWithError:loadError];
      });
      return;
    }

    // Register the display link to start sending js calls after everything is setup
    NSRunLoop *targetRunLoop = [self->_javaScriptExecutor isKindOfClass:[ABI9_0_0RCTJSCExecutor class]] ? [NSRunLoop currentRunLoop] : [NSRunLoop mainRunLoop];
    [self->_displayLink addToRunLoop:targetRunLoop];

    // Perform the notification on the main thread, so we can't run into
    // timing issues with ABI9_0_0RCTRootView
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
       postNotificationName:ABI9_0_0RCTJavaScriptDidLoadNotification
       object:self->_parentBridge userInfo:@{@"bridge": self}];
    });

    [self _flushPendingCalls];
  }];

#if ABI9_0_0RCT_DEV
  if ([ABI9_0_0RCTGetURLQueryParam(self.bundleURL, @"hot") boolValue]) {
    NSString *path = [self.bundleURL.path substringFromIndex:1]; // strip initial slash
    NSString *host = self.bundleURL.host;
    NSNumber *port = self.bundleURL.port;
    [self enqueueJSCall:@"HMRClient.enable" args:@[@"ios", path, host, ABI9_0_0RCTNullIfNil(port)]];
  }
#endif
}

- (void)_flushPendingCalls
{
  ABI9_0_0RCTAssertJSThread();
  [_performanceLogger markStopForTag:ABI9_0_0RCTPLBridgeStartup];

  ABI9_0_0RCT_PROFILE_BEGIN_EVENT(0, @"Processing pendingCalls", @{ @"count": @(_pendingCalls.count) });
  _loading = NO;
  NSArray *pendingCalls = _pendingCalls;
  _pendingCalls = nil;
  for (dispatch_block_t call in pendingCalls) {
    call();
  }
  ABI9_0_0RCT_PROFILE_END_EVENT(0, @"", nil);
}

- (void)stopLoadingWithError:(NSError *)error
{
  ABI9_0_0RCTAssertMainQueue();

  if (!_valid || !_loading) {
    return;
  }

  _loading = NO;
  [_javaScriptExecutor invalidate];

  [[NSNotificationCenter defaultCenter]
   postNotificationName:ABI9_0_0RCTJavaScriptDidFailToLoadNotification
   object:_parentBridge userInfo:@{@"bridge": self, @"error": error}];

  if ([error userInfo][ABI9_0_0RCTJSStackTraceKey]) {
    [self.redBox showErrorMessage:[error localizedDescription]
                        withStack:[error userInfo][ABI9_0_0RCTJSStackTraceKey]];
  }
  ABI9_0_0RCTFatal(error);
}

ABI9_0_0RCT_NOT_IMPLEMENTED(- (instancetype)initWithBundleURL:(__unused NSURL *)bundleURL
                    moduleProvider:(__unused ABI9_0_0RCTBridgeModuleProviderBlock)block
                    launchOptions:(__unused NSDictionary *)launchOptions)

/**
 * Prevent super from calling setUp (that'd create another batchedBridge)
 */
- (void)setUp {}
- (void)bindKeys {}

- (void)reload
{
  [_parentBridge reload];
}

- (Class)executorClass
{
  return _parentBridge.executorClass ?: [ABI9_0_0RCTJSCExecutor class];
}

- (void)setExecutorClass:(Class)executorClass
{
  ABI9_0_0RCTAssertMainQueue();

  _parentBridge.executorClass = executorClass;
}

- (NSURL *)bundleURL
{
  return _parentBridge.bundleURL;
}

- (void)setBundleURL:(NSURL *)bundleURL
{
  _parentBridge.bundleURL = bundleURL;
}

- (id<ABI9_0_0RCTBridgeDelegate>)delegate
{
  return _parentBridge.delegate;
}

- (BOOL)isLoading
{
  return _loading;
}

- (BOOL)isValid
{
  return _valid;
}

- (void)dispatchBlock:(dispatch_block_t)block
                queue:(dispatch_queue_t)queue
{
  if (queue == ABI9_0_0RCTJSThread) {
    __weak __typeof(self) weakSelf = self;
    ABI9_0_0RCTProfileBeginFlowEvent();
    ABI9_0_0RCTAssert(_javaScriptExecutor != nil, @"Need JS executor to schedule JS work");

    [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
      ABI9_0_0RCTProfileEndFlowEvent();

      ABI9_0_0RCTBatchedBridge *strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }

      if (strongSelf.loading) {
        [strongSelf->_pendingCalls addObject:block];
      } else {
        block();
      }
    }];
  } else if (queue) {
    dispatch_async(queue, block);
  }
}

#pragma mark - ABI9_0_0RCTInvalidating

- (void)invalidate
{
  if (!_valid) {
    return;
  }

  ABI9_0_0RCTAssertMainQueue();
  ABI9_0_0RCTAssert(_javaScriptExecutor != nil, @"Can't complete invalidation without a JS executor");

  _loading = NO;
  _valid = NO;
  if ([ABI9_0_0RCTBridge currentBridge] == self) {
    [ABI9_0_0RCTBridge setCurrentBridge:nil];
  }

  // Invalidate modules
  dispatch_group_t group = dispatch_group_create();
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    // Be careful when grabbing an instance here, we don't want to instantiate
    // any modules just to invalidate them.
    id<ABI9_0_0RCTBridgeModule> instance = nil;
    if ([moduleData hasInstance]) {
      instance = moduleData.instance;
    }

    if (instance == _javaScriptExecutor) {
      continue;
    }

    if ([instance respondsToSelector:@selector(invalidate)]) {
      dispatch_group_enter(group);
      [self dispatchBlock:^{
        [(id<ABI9_0_0RCTInvalidating>)instance invalidate];
        dispatch_group_leave(group);
      } queue:moduleData.methodQueue];
    }
    [moduleData invalidate];
  }

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    [self->_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
      [self->_displayLink invalidate];
      self->_displayLink = nil;

      [self->_javaScriptExecutor invalidate];
      self->_javaScriptExecutor = nil;

      if (ABI9_0_0RCTProfileIsProfiling()) {
        ABI9_0_0RCTProfileUnhookModules(self);
      }

      self->_moduleDataByName = nil;
      self->_moduleDataByID = nil;
      self->_moduleClassesByID = nil;
      self->_pendingCalls = nil;

      if (self->_flowIDMap != NULL) {
        CFRelease(self->_flowIDMap);
      }
    }];
  });
}

- (void)logMessage:(NSString *)message level:(NSString *)level
{
  if (ABI9_0_0RCT_DEBUG && [_javaScriptExecutor isValid]) {
    [self enqueueJSCall:@"ABI9_0_0RCTLog.logIfNoNativeHook"
                   args:@[level, message]];
  }
}

#pragma mark - ABI9_0_0RCTBridge methods

/**
 * Public. Can be invoked from any thread.
 */
- (void)enqueueJSCall:(NSString *)module method:(NSString *)method args:(NSArray *)args completion:(dispatch_block_t)completion
{
 module = ABI9_0_0EX_REMOVE_VERSION(module);
 /**
   * AnyThread
   */
  ABI9_0_0RCT_PROFILE_BEGIN_EVENT(ABI9_0_0RCTProfileTagAlways, @"-[ABI9_0_0RCTBatchedBridge enqueueJSCall:]", nil);
  if (!_valid) {
    return;
  }

  __weak __typeof(self) weakSelf = self;
  [self dispatchBlock:^{
    [weakSelf _actuallyInvokeAndProcessModule:module method:method arguments:args ?: @[]];
    if (completion) {
      completion();
    }
  } queue:ABI9_0_0RCTJSThread];

  ABI9_0_0RCT_PROFILE_END_EVENT(ABI9_0_0RCTProfileTagAlways, @"", nil);
}

/**
 * Called by ABI9_0_0RCTModuleMethod from any thread.
 */
- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args
{
  /**
   * AnyThread
   */
  if (!_valid) {
    return;
  }

  __weak __typeof(self) weakSelf = self;
  [self dispatchBlock:^{
    [weakSelf _actuallyInvokeCallback:cbID arguments:args];
  } queue:ABI9_0_0RCTJSThread];
}

/**
 * Private hack to support `setTimeout(fn, 0)`
 */
- (void)_immediatelyCallTimer:(NSNumber *)timer
{
  ABI9_0_0RCTAssertJSThread();
  [_javaScriptExecutor executeAsyncBlockOnJavaScriptQueue:^{
    [self _actuallyInvokeAndProcessModule:@"JSTimersExecution"
                                   method:@"callTimers"
                                arguments:@[@[timer]]];
  }];
}

- (void)enqueueApplicationScript:(NSData *)script
                             url:(NSURL *)url
                      onComplete:(ABI9_0_0RCTJavaScriptCompleteBlock)onComplete
{
  ABI9_0_0RCTAssert(onComplete != nil, @"onComplete block passed in should be non-nil");

  ABI9_0_0RCTProfileBeginFlowEvent();
  [_javaScriptExecutor executeApplicationScript:script sourceURL:url onComplete:^(NSError *scriptLoadError) {
    ABI9_0_0RCTProfileEndFlowEvent();
    ABI9_0_0RCTAssertJSThread();

    if (scriptLoadError) {
      onComplete(scriptLoadError);
      return;
    }

    ABI9_0_0RCT_PROFILE_BEGIN_EVENT(ABI9_0_0RCTProfileTagAlways, @"FetchApplicationScriptCallbacks", nil);
    [self->_javaScriptExecutor flushedQueue:^(id json, NSError *error)
     {
       ABI9_0_0RCT_PROFILE_END_EVENT(ABI9_0_0RCTProfileTagAlways, @"js_call,init", @{
         @"json": ABI9_0_0RCTNullIfNil(json),
         @"error": ABI9_0_0RCTNullIfNil(error),
       });

       [self handleBuffer:json batchEnded:YES];

       onComplete(error);
     }];
  }];
}

#pragma mark - Payload Generation

- (void)_actuallyInvokeAndProcessModule:(NSString *)module
                                 method:(NSString *)method
                              arguments:(NSArray *)args
{
  ABI9_0_0RCTAssertJSThread();

  __weak typeof(self) weakSelf = self;
  [_javaScriptExecutor callFunctionOnModule:module
                                     method:method
                                  arguments:args
                                   callback:^(id json, NSError *error) {
                                     [weakSelf _processResponse:json error:error];
                                   }];
}

- (void)_actuallyInvokeCallback:(NSNumber *)cbID
                      arguments:(NSArray *)args
{
  ABI9_0_0RCTAssertJSThread();

  __weak typeof(self) weakSelf = self;
  [_javaScriptExecutor invokeCallbackID:cbID
                              arguments:args
                               callback:^(id json, NSError *error) {
                                 [weakSelf _processResponse:json error:error];
                               }];
}

- (void)_processResponse:(id)json error:(NSError *)error
{
  if (error) {
    if ([error userInfo][ABI9_0_0RCTJSStackTraceKey]) {
      [self.redBox showErrorMessage:[error localizedDescription]
                          withStack:[error userInfo][ABI9_0_0RCTJSStackTraceKey]];
    }
    ABI9_0_0RCTFatal(error);
  }

  if (!_valid) {
    return;
  }
  [self handleBuffer:json batchEnded:YES];
}

#pragma mark - Payload Processing

- (void)handleBuffer:(id)buffer batchEnded:(BOOL)batchEnded
{
  ABI9_0_0RCTAssertJSThread();

  if (buffer != nil && buffer != (id)kCFNull) {
    _wasBatchActive = YES;
    [self handleBuffer:buffer];
    [self partialBatchDidFlush];
  }

  if (batchEnded) {
    if (_wasBatchActive) {
      [self batchDidComplete];
    }

    _wasBatchActive = NO;
  }
}

- (void)handleBuffer:(NSArray *)buffer
{
  NSArray *requestsArray = [ABI9_0_0RCTConvert NSArray:buffer];

  if (ABI9_0_0RCT_DEBUG && requestsArray.count <= ABI9_0_0RCTBridgeFieldParams) {
    ABI9_0_0RCTLogError(@"Buffer should contain at least %tu sub-arrays. Only found %tu",
                ABI9_0_0RCTBridgeFieldParams + 1, requestsArray.count);
    return;
  }

  NSArray<NSNumber *> *moduleIDs = [ABI9_0_0RCTConvert NSNumberArray:requestsArray[ABI9_0_0RCTBridgeFieldRequestModuleIDs]];
  NSArray<NSNumber *> *methodIDs = [ABI9_0_0RCTConvert NSNumberArray:requestsArray[ABI9_0_0RCTBridgeFieldMethodIDs]];
  NSArray<NSArray *> *paramsArrays = [ABI9_0_0RCTConvert NSArrayArray:requestsArray[ABI9_0_0RCTBridgeFieldParams]];

  int64_t callID = -1;

  if (requestsArray.count > 3) {
    callID = [requestsArray[ABI9_0_0RCTBridgeFieldCallID] longLongValue];
  }

  if (ABI9_0_0RCT_DEBUG && (moduleIDs.count != methodIDs.count || moduleIDs.count != paramsArrays.count)) {
    ABI9_0_0RCTLogError(@"Invalid data message - all must be length: %zd", moduleIDs.count);
    return;
  }

  NSMapTable *buckets = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                                  valueOptions:NSPointerFunctionsStrongMemory
                                                      capacity:_moduleDataByName.count];

  [moduleIDs enumerateObjectsUsingBlock:^(NSNumber *moduleID, NSUInteger i, __unused BOOL *stop) {
    ABI9_0_0RCTModuleData *moduleData = self->_moduleDataByID[moduleID.integerValue];
    dispatch_queue_t queue = moduleData.methodQueue;
    NSMutableOrderedSet<NSNumber *> *set = [buckets objectForKey:queue];
    if (!set) {
      set = [NSMutableOrderedSet new];
      [buckets setObject:set forKey:queue];
    }
    [set addObject:@(i)];
  }];

  for (dispatch_queue_t queue in buckets) {
    ABI9_0_0RCTProfileBeginFlowEvent();

    dispatch_block_t block = ^{
      ABI9_0_0RCTProfileEndFlowEvent();
      ABI9_0_0RCT_PROFILE_BEGIN_EVENT(ABI9_0_0RCTProfileTagAlways, @"-[ABI9_0_0RCTBatchedBridge handleBuffer:]", nil);

      NSOrderedSet *calls = [buckets objectForKey:queue];
      @autoreleasepool {
        for (NSNumber *indexObj in calls) {
          NSUInteger index = indexObj.unsignedIntegerValue;
          if (ABI9_0_0RCT_DEV && callID != -1 && self->_flowIDMap != NULL && ABI9_0_0RCTProfileIsProfiling()) {
            [self.flowIDMapLock lock];
            int64_t newFlowID = (int64_t)CFDictionaryGetValue(self->_flowIDMap, (const void *)(self->_flowID + index));
            _ABI9_0_0RCTProfileEndFlowEvent(@(newFlowID));
            CFDictionaryRemoveValue(self->_flowIDMap, (const void *)(self->_flowID + index));
            [self.flowIDMapLock unlock];
          }
          [self _handleRequestNumber:index
                            moduleID:[moduleIDs[index] integerValue]
                            methodID:[methodIDs[index] integerValue]
                              params:paramsArrays[index]];
        }
      }

      ABI9_0_0RCT_PROFILE_END_EVENT(ABI9_0_0RCTProfileTagAlways, @"objc_call,dispatch_async", @{
        @"calls": @(calls.count),
      });
    };

    [self dispatchBlock:block queue:queue];
  }

  _flowID = callID;
}

- (void)partialBatchDidFlush
{
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.implementsPartialBatchDidFlush) {
      [self dispatchBlock:^{
        [moduleData.instance partialBatchDidFlush];
      } queue:moduleData.methodQueue];
    }
  }
}

- (void)batchDidComplete
{
  // TODO: batchDidComplete is only used by ABI9_0_0RCTUIManager - can we eliminate this special case?
  for (ABI9_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.implementsBatchDidComplete) {
      [self dispatchBlock:^{
        [moduleData.instance batchDidComplete];
      } queue:moduleData.methodQueue];
    }
  }
}

- (BOOL)_handleRequestNumber:(NSUInteger)i
                    moduleID:(NSUInteger)moduleID
                    methodID:(NSUInteger)methodID
                      params:(NSArray *)params
{
  if (!_valid) {
    return NO;
  }

  if (ABI9_0_0RCT_DEBUG && ![params isKindOfClass:[NSArray class]]) {
    ABI9_0_0RCTLogError(@"Invalid module/method/params tuple for request #%zd", i);
    return NO;
  }

  ABI9_0_0RCTModuleData *moduleData = _moduleDataByID[moduleID];
  if (ABI9_0_0RCT_DEBUG && !moduleData) {
    ABI9_0_0RCTLogError(@"No module found for id '%zd'", moduleID);
    return NO;
  }

  id<ABI9_0_0RCTBridgeMethod> method = moduleData.methods[methodID];
  if (ABI9_0_0RCT_DEBUG && !method) {
    ABI9_0_0RCTLogError(@"Unknown methodID: %zd for module: %zd (%@)", methodID, moduleID, moduleData.name);
    return NO;
  }

  @try {
    [method invokeWithBridge:self module:moduleData.instance arguments:params];
  }
  @catch (NSException *exception) {
    // Pass on JS exceptions
    if ([exception.name hasPrefix:ABI9_0_0RCTFatalExceptionName]) {
      @throw exception;
    }

    NSString *message = [NSString stringWithFormat:
                         @"Exception '%@' was thrown while invoking %@ on target %@ with params %@",
                         exception, method.JSMethodName, moduleData.name, params];
    ABI9_0_0RCTFatal(ABI9_0_0RCTErrorWithMessage(message));
  }

  return YES;
}

- (void)startProfiling
{
  ABI9_0_0RCTAssertMainQueue();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI9_0_0RCTProfileInit(self);
  }];
}

- (void)stopProfiling:(void (^)(NSData *))callback
{
  ABI9_0_0RCTAssertMainQueue();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI9_0_0RCTProfileEnd(self, ^(NSString *log) {
      NSData *logData = [log dataUsingEncoding:NSUTF8StringEncoding];
      callback(logData);
    });
  }];
}

- (BOOL)isBatchActive
{
  return _wasBatchActive;
}

- (ABI9_0_0RCTBridge *)baseBridge
{
  return _parentBridge;
}

@end

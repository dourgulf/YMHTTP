//
//  YMURLSessionTask.m
//  YMHTTP
//
//  Created by zymxxxs on 2020/2/5.
//

#import "YMURLSessionTask.h"
#import "NSInputStream+YMCategory.h"
#import "YMEasyHandle.h"
#import "YMMacro.h"
#import "YMTaskRegistry.h"
#import "YMTimeoutSource.h"
#import "YMTransferState.h"
#import "YMURLSession.h"
#import "YMURLSessionConfiguration.h"
#import "YMURLSessionDelegate.h"
#import "YMURLSessionTaskBehaviour.h"
#import "YMURLSessionTaskBody.h"
#import "YMURLSessionTaskBodySource.h"

typedef NS_ENUM(NSUInteger, YMURLSessionTaskInternalState) {
    /// Task has been created, but nothing has been done, yet
    YMURLSessionTaskInternalStateInitial,
    /// The task is being fulfilled from the cache rather than the network.
    YMURLSessionTaskInternalStateFulfillingFromCache,
    /// The easy handle has been fully configured. But it is not added to
    /// the multi handle.
    YMURLSessionTaskInternalStateTransferReady,
    /// The easy handle is currently added to the multi handle
    YMURLSessionTaskInternalStateTransferInProgress,
    /// The transfer completed.
    ///
    /// The easy handle has been removed from the multi handle. This does
    /// not necessarily mean the task completed. A task that gets
    /// redirected will do multiple transfers.
    YMURLSessionTaskInternalStateTransferCompleted,
    /// The transfer failed.
    ///
    /// Same as `.transferCompleted`, but without response / body data
    YMURLSessionTaskInternalStateTransferFailed,
    /// Waiting for the completion handler of the HTTP redirect callback.
    ///
    /// When we tell the delegate that we're about to perform an HTTP
    /// redirect, we need to wait for the delegate to let us know what
    /// action to take.
    YMURLSessionTaskInternalStateWaitingForRedirectHandler,
    /// Waiting for the completion handler of the 'did receive response' callback.
    ///
    /// When we tell the delegate that we received a response (i.e. when
    /// we received a complete header), we need to wait for the delegate to
    /// let us know what action to take. In this state the easy handle is
    /// paused in order to suspend delegate callbacks.
    YMURLSessionTaskInternalStateWaitingForResponseHandler,
    /// The task is completed
    ///
    /// Contrast this with `.transferCompleted`.
    YMURLSessionTaskInternalStateTaskCompleted,
};

@interface YMURLSessionTask () <YMEasyHandleDelegate>

@property (nonatomic, strong) YMURLSession *session;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, assign) NSUInteger suspendCount;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSURLRequest *authRequest;

@property (nonatomic, strong) NSData *responseData;

@property (nonatomic, strong) YMEasyHandle *easyHandle;
@property (nonatomic, assign) YMURLSessionTaskInternalState internalState;
@property (nonatomic, strong) YMTransferState *transferState;
@property (nonatomic, strong) NSCachedURLResponse *cachedResponse;
@property (nonatomic, strong) YMURLSessionTaskBody *knownBody;

@end

@implementation YMURLSessionTask

/// Create a data task. If there is a httpBody in the URLRequest, use that as a parameter
- (instancetype)initWithSession:(YMURLSession *)session
                        reqeust:(NSURLRequest *)request
                 taskIdentifier:(NSUInteger)taskIdentifier {
    if (request.HTTPBody) {
        YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] initWithData:request.HTTPBody];
        return [self initWithSession:session reqeust:request taskIdentifier:taskIdentifier body:body];
    } else if (request.HTTPBodyStream) {
        YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] initWithInputStream:request.HTTPBodyStream];
        return [self initWithSession:session reqeust:request taskIdentifier:taskIdentifier body:body];
    } else {
        YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] init];
        return [self initWithSession:session reqeust:request taskIdentifier:taskIdentifier body:body];
    }
}

- (instancetype)initWithSession:(YMURLSession *)session
                        reqeust:(NSURLRequest *)request
                 taskIdentifier:(NSUInteger)taskIdentifier
                           body:(YMURLSessionTaskBody *)body {
    self = [super init];
    if (self) {
        [self setupProps];
        _session = session;
        _workQueue = dispatch_queue_create_with_target(
            "com.zymxxxs.URLSessionTask.WrokQueue", DISPATCH_QUEUE_SERIAL, session.workQueue);
        _taskIdentifier = taskIdentifier;
        _originalRequest = request;
        _knownBody = body;
        _currentRequest = request;
    }
    return self;
}

- (void)setupProps {
    _state = YMURLSessionTaskStateSuspended;
    _suspendCount = 1;
}

- (void)resume {
    dispatch_sync(_workQueue, ^{
        if (_state == YMURLSessionTaskStateCanceling || _state == YMURLSessionTaskStateCompleted) return;
        _suspendCount -= 1;
        if (_suspendCount > 0) {
            // TODO: throw Error
        }
        [self updateTaskState];
        if (_suspendCount == 0) {
            BOOL isHTTPScheme = [_originalRequest.URL.scheme isEqualToString:@"http"] ||
                                [_originalRequest.URL.scheme isEqualToString:@"https"];
            if (isHTTPScheme) {
                // TODO: lock protocol
                _easyHandle = [[YMEasyHandle alloc] initWithDelegate:self];
                self.internalState = YMURLSessionTaskInternalStateInitial;
                dispatch_async(_workQueue, ^{
                    [self startLoading];
                });
            } else {
                if (_error == nil) {
                    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
                    userInfo[NSLocalizedDescriptionKey] = @"unsupported URL";
                    NSURL *url = _originalRequest.URL;
                    if (url) {
                        userInfo[NSURLErrorFailingURLErrorKey] = url;
                        userInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString;
                    }
                    NSError *urlError = [NSError errorWithDomain:NSURLErrorDomain
                                                            code:NSURLErrorUnsupportedURL
                                                        userInfo:userInfo];
                    _error = urlError;
                }
            }
        }
    });
}

#pragma mark - Setter Methods

- (void)setInternalState:(YMURLSessionTaskInternalState)internalState {
    YMURLSessionTaskInternalState newValue = internalState;
    if (![self isEasyHandlePausedForState:_internalState] && [self isEasyHandlePausedForState:newValue]) {
        // TODO: Error
    }

    if ([self isEasyHandleAddedToMultiHandleForState:_internalState] &&
        ![self isEasyHandleAddedToMultiHandleForState:newValue]) {
        [_session removeHandle:_easyHandle];
    }

    // set
    YMURLSessionTaskInternalState oldValue = _internalState;
    _internalState = internalState;

    if (![self isEasyHandleAddedToMultiHandleForState:oldValue] &&
        [self isEasyHandleAddedToMultiHandleForState:_internalState]) {
        [_session addHandle:_easyHandle];
    }

    if ([self isEasyHandlePausedForState:oldValue] && ![self isEasyHandlePausedForState:_internalState]) {
        // TODO: Error Need to solve pausing receive.
    }
}

- (BOOL)isEasyHandlePausedForState:(YMURLSessionTaskInternalState)state {
    switch (state) {
        case YMURLSessionTaskInternalStateInitial:
            return false;
        case YMURLSessionTaskInternalStateFulfillingFromCache:
            return false;
        case YMURLSessionTaskInternalStateTransferReady:
            return false;
        case YMURLSessionTaskInternalStateTransferInProgress:
            return false;
        case YMURLSessionTaskInternalStateTransferCompleted:
            return false;
        case YMURLSessionTaskInternalStateTransferFailed:
            return false;
        case YMURLSessionTaskInternalStateWaitingForRedirectHandler:
            return false;
        case YMURLSessionTaskInternalStateWaitingForResponseHandler:
            return true;
        case YMURLSessionTaskInternalStateTaskCompleted:
            return false;
    }
}

- (BOOL)isEasyHandleAddedToMultiHandleForState:(YMURLSessionTaskInternalState)state {
    switch (state) {
        case YMURLSessionTaskInternalStateInitial:
            return false;
        case YMURLSessionTaskInternalStateFulfillingFromCache:
            return false;
        case YMURLSessionTaskInternalStateTransferReady:
            return false;
        case YMURLSessionTaskInternalStateTransferInProgress:
            return true;
        case YMURLSessionTaskInternalStateTransferCompleted:
            return false;
        case YMURLSessionTaskInternalStateTransferFailed:
            return false;
        case YMURLSessionTaskInternalStateWaitingForRedirectHandler:
            return false;
        case YMURLSessionTaskInternalStateWaitingForResponseHandler:
            return true;
        case YMURLSessionTaskInternalStateTaskCompleted:
            return false;
    }
}

#pragma mark - Private Methods

- (void)updateTaskState {
    if (_suspendCount == 0) {
        _state = YMURLSessionTaskStateRunning;
    } else {
        _state = YMURLSessionTaskStateSuspended;
    }
}

- (BOOL)canRespondFromCacheUsingResponse:(NSCachedURLResponse *)response {
    // TODO:
    return true;
}

- (void)startNewTransferByRequest:(NSURLRequest *)request {
    if (!request.URL) {
        // TODO: error
    }

    [self getBodyWithCompletion:^(YMURLSessionTaskBody *body) {
        self.internalState = YMURLSessionTaskInternalStateTransferReady;
        self.transferState = [self createTransferStateWithURL:request.URL body:body workQueue:self.workQueue];
        NSURLRequest *r = self.authRequest ?: request;
        [self configureEasyHandleForRequest:r body:body];
        if (self.suspendCount < 1) {
            [self startLoading];
        }
    }];
}

- (void)getBodyWithCompletion:(void (^)(YMURLSessionTaskBody *body))completion {
    if (_knownBody) {
        completion(_knownBody);
        return;
    };

    if (_session && _session.delegate && [_session.delegate conformsToProtocol:@protocol(YMURLSessionTaskDelegate)] &&
        [_session.delegate respondsToSelector:@selector(YMURLSession:task:needNewBodyStream:)]) {
        id<YMURLSessionTaskDelegate> delegate = (id<YMURLSessionTaskDelegate>)_session.delegate;
        [delegate YMURLSession:_session
                          task:self
             needNewBodyStream:^(NSInputStream *_Nullable bodyStream) {
                 if (bodyStream) {
                     YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] initWithInputStream:bodyStream];
                     completion(body);
                 } else {
                     YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] init];
                     completion(body);
                 }
             }];
    } else {
        YMURLSessionTaskBody *body = [[YMURLSessionTaskBody alloc] init];
        completion(body);
    }
}

- (void)configureEasyHandleForRequest:(NSURLRequest *)request body:(YMURLSessionTaskBody *)body {
    BOOL debugLibcurl = NSProcessInfo.processInfo.environment[@"URLSessionDebugLibcurl"];
    [_easyHandle setVerboseMode:debugLibcurl];
    BOOL debugOutput = NSProcessInfo.processInfo.environment[@"URLSessionDebug"];
    [_easyHandle setDebugOutput:debugOutput task:self];
    [_easyHandle setPassHeadersToDataStream:false];
    [_easyHandle setProgressMeterOff:true];
    [_easyHandle setSkipAllSignalHandling:true];

    // Error Options:
    [_easyHandle setErrorBuffer:NULL];
    [_easyHandle setFailOnHTTPErrorCode:false];

    if (!request.URL) {
        // TODO: error
    }
    [_easyHandle setURL:request.URL];
    [_easyHandle setSessionConfig:_session.configuration];
    [_easyHandle setAllowedProtocolsToHTTPAndHTTPS];
    [_easyHandle setPreferredReceiveBufferSize:NSIntegerMax];

    NSError *e = nil;
    NSNumber *bodySize = [body getBodyLengthWithError:&e];
    if (e) {
        self.internalState = YMURLSessionTaskInternalStateTransferFailed;
        NSInteger errorCode = [self errorCodeFromFileSystemError:e];
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:errorCode
                                         userInfo:@{NSLocalizedDescriptionKey : @"File system error"}];
        [self failWithError:error request:request];
        return;
    }
    if (body.type == YMURLSessionTaskBodyTypeNone) {
        [_easyHandle setUpload:false];
        [_easyHandle setRequestBodyLength:0];
    } else if (bodySize) {
        [_easyHandle setUpload:true];
        [_easyHandle setRequestBodyLength:bodySize.unsignedLongLongValue];
    } else if (!bodySize) {
        [_easyHandle setUpload:true];
        [_easyHandle setRequestBodyLength:-1];
    }

    [_easyHandle setFollowLocation:false];

    // The httpAdditionalHeaders from session configuration has to be added to the request.
    // The request.allHTTPHeaders can override the httpAdditionalHeaders elements. Add the
    // httpAdditionalHeaders from session configuration first and then append/update the
    // request.allHTTPHeaders so that request.allHTTPHeaders can override httpAdditionalHeaders.
    NSMutableDictionary *hh = [NSMutableDictionary dictionary];
    NSDictionary *HTTPAdditionalHeaders = _session.configuration.HTTPAdditionalHeaders ?: @{};
    NSDictionary *HTTPHeaders = request.allHTTPHeaderFields ?: @{};
    [hh addEntriesFromDictionary:[self transformLowercaseKeyForHTTPHeaders:HTTPAdditionalHeaders]];
    [hh addEntriesFromDictionary:[self transformLowercaseKeyForHTTPHeaders:HTTPHeaders]];

    NSArray *curlHeaders = [self curlHeadersForHTTPHeaders:hh];
    if ([request.HTTPMethod isEqualToString:@"POST"] && (request.HTTPBody.length > 0) &&
        ([request valueForHTTPHeaderField:@"Content-Type"] == nil)) {
        NSMutableArray *temp = [curlHeaders mutableCopy];
        [temp addObject:@"Content-Type:application/x-www-form-urlencoded"];
        curlHeaders = temp;
    }
    [_easyHandle setCustomHeaders:curlHeaders];

    // TODO: timeoutInterval set or get
    NSInteger timeoutInterval = [_session.configuration timeoutIntervalForRequest] * 1000;
    _easyHandle.timeoutTimer = [[YMTimeoutSource alloc]
        initWithQueue:_workQueue
         milliseconds:timeoutInterval
              handler:^{
                  self.internalState = YMURLSessionTaskInternalStateTransferFailed;
                  NSError *urlError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
                  [self completeTaskWithError:urlError];
                  // TODO: protocol
              }];
    [_easyHandle setAutomaticBodyDecompression:true];
    [_easyHandle setRequestMethod:request.HTTPMethod ?: @"GET"];
    if ([request.HTTPMethod isEqualToString:@"HEAD"]) {
        [_easyHandle setNoBody:true];
    }
}

- (YMTransferState *)createTransferStateWithURL:(NSURL *)url
                                           body:(YMURLSessionTaskBody *)body
                                      workQueue:(dispatch_queue_t)workQueue {
    YMDataDrain *drain = [self createTransferBodyDataDrain];
    switch (body.type) {
        case YMURLSessionTaskBodyTypeNone:
            return [[YMTransferState alloc] initWithURL:url bodyDataDrain:drain];
            break;
        case YMURLSessionTaskBodyTypeData: {
            YMBodyDataSource *source = [[YMBodyDataSource alloc] initWithData:body.data];
            return [[YMTransferState alloc] initWithURL:url bodyDataDrain:drain bodySource:source];
        }
        case YMURLSessionTaskBodyTypeFile:
            // TODO: fix
            break;
        case YMURLSessionTaskBodyTypeStream: {
            YMBodyStreamSource *source = [[YMBodyStreamSource alloc] initWithInputStream:body.inputStream];
            return [[YMTransferState alloc] initWithURL:url bodyDataDrain:drain bodySource:source];
        }
    }
    // TODO: '''
    return nil;
}

- (YMDataDrain *)createTransferBodyDataDrain {
    YMURLSession *s = _session;
    YMURLSessionTaskBehaviour *b = [s behaviourForTask:self];
    YMDataDrain *dd = [[YMDataDrain alloc] init];
    switch (b.type) {
        case YMURLSessionTaskBehaviourTypeNoDelegate:
            dd.type = YMDataDrainTypeIgnore;
            return dd;
        case YMURLSessionTaskBehaviourTypeTaskDelegate:
            dd.type = YMDataDrainTypeIgnore;
            return dd;
        case YMURLSessionTaskBehaviourTypeDataHandler:
            dd.type = YMDataDrainInMemory;
            dd.data = nil;
            return dd;
        case YMURLSessionTaskBehaviourTypeDownloadHandler:
            // TODO: Download
            break;
    }

    return nil;
}

- (NSInteger)errorCodeFromFileSystemError:(NSError *)error {
    if (error.domain == NSCocoaErrorDomain) {
        switch (error.code) {
            case NSFileReadNoSuchFileError:
                return NSURLErrorFileDoesNotExist;
            case NSFileReadNoPermissionError:
                return NSURLErrorNoPermissionsToReadFile;
            default:
                return NSURLErrorUnknown;
        }
    } else {
        return NSURLErrorUnknown;
    }
}

- (void)failWithError:(NSError *)error request:(NSURLRequest *)request {
    NSDictionary *userInfo = @{
        NSUnderlyingErrorKey : error,
        NSURLErrorFailingURLErrorKey : request.URL,
        NSURLErrorFailingURLStringErrorKey : request.URL.absoluteString,
        NSLocalizedDescriptionKey : NSLocalizedString(error.localizedDescription, @"N/A")
    };

    NSError *urlError = [NSError errorWithDomain:NSURLErrorDomain code:error.code userInfo:userInfo];
    [self completeTaskWithError:urlError];
    [self notifyDelegateAboutError:urlError];
}

- (void)completeTask {
    if (self.internalState != YMURLSessionTaskInternalStateTransferCompleted) {
        // TODO: Error
    }

    _response = _transferState.response;
    _easyHandle.timeoutTimer = nil;

    YMDataDrain *bodyData = _transferState.bodyDataDrain;
    if (bodyData.type == YMDataDrainInMemory) {
        NSData *data = [NSData data];
        if (bodyData.data) {
            data = [[NSData alloc] initWithData:bodyData.data];
        }
        [self notifyDelegateAboutLoadData:data];
        self.internalState = YMURLSessionTaskInternalStateTaskCompleted;
    } else if (bodyData.type == YMDataDrainTypeToFile) {
        // TODO:
    } else if (true) {
        // TODO: downloadn task
    }

    [self notifyDelegateAboutFinishLoading];
    self.internalState = YMURLSessionTaskInternalStateTaskCompleted;
}

- (void)completeTaskWithError:(NSError *)error {
    _error = error;
    if (self.internalState != YMURLSessionTaskInternalStateTransferFailed) {
        // TODO: throw
    }

    _easyHandle.timeoutTimer = nil;
    self.internalState = YMURLSessionTaskInternalStateTaskCompleted;
}

#pragma mark - Redirect Methods

- (void)redirectForRequest:(NSURLRequest *)reqeust {
    if (self.internalState != YMURLSessionTaskInternalStateTransferCompleted) {
        // TODO: Error
    }
    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    if (b.type == YMURLSessionTaskBehaviourTypeTaskDelegate) {
        BOOL isResponds = [_session.delegate
            respondsToSelector:@selector(YMURLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)];
        if (isResponds) {
            self.internalState = YMURLSessionTaskInternalStateWaitingForRedirectHandler;
            [_session.delegateQueue addOperationWithBlock:^{
                id<YMURLSessionTaskDelegate> d = (id<YMURLSessionTaskDelegate>)self.session.delegate;
                [d YMURLSession:self.session
                                          task:self
                    willPerformHTTPRedirection:self.transferState.response
                                    newRequest:reqeust
                             completionHandler:^(NSURLRequest *_Nullable request) {
                                 dispatch_async(self.workQueue, ^{
                                     if (self.internalState != YMURLSessionTaskInternalStateTransferCompleted) {
                                         // TODO: Error
                                     }
                                     if (request) {
                                         [self startNewTransferByRequest:request];
                                     } else {
                                         self.internalState = YMURLSessionTaskInternalStateTransferCompleted;
                                         [self completeTask];
                                     }
                                 });
                             }];
            }];
        } else {
            NSURLRequest *configuredRequest = [_session.configuration configureRequest:reqeust];
            [self startNewTransferByRequest:configuredRequest];
        }
    } else {
        NSURLRequest *configuredRequest = [_session.configuration configureRequest:reqeust];
        [self startNewTransferByRequest:configuredRequest];
    }
}

- (NSURLRequest *)redirectedReqeustForResponse:(NSHTTPURLResponse *)response fromRequest:(NSURLRequest *)fromRequest {
    NSString *method = nil;
    NSURL *targetURL = nil;

    NSString *location = response.allHeaderFields[@"Location"];
    targetURL = [NSURL URLWithString:location];
    if (!location && !targetURL) return nil;

    switch (response.statusCode) {
        case 301:
        case 302:
        case 303:
            method = @"GET";
            break;
        case 307:
            method = fromRequest.HTTPMethod ?: @"GET";
            break;
        default:
            return nil;
    }

    NSMutableURLRequest *request = [fromRequest mutableCopy];
    request.HTTPMethod = method;

    if (targetURL.scheme && targetURL.host) {
        request.URL = targetURL;
        return request;
    }

    NSString *scheme = request.URL.scheme;
    NSString *host = request.URL.host;
    NSNumber *port = request.URL.port;

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = host;
    // Use the original port if the new URL does not contain a host
    // ie Location: /foo => <original host>:<original port>/Foo
    // but Location: newhost/foo  will ignore the original port
    if (targetURL.host == nil) {
        components.port = port;
    }
    // The path must either begin with "/" or be an empty string.
    if (![targetURL.relativePath hasPrefix:@"/"]) {
        components.path = [NSString stringWithFormat:@"/%@", targetURL.relativePath];
    } else {
        components.path = targetURL.relativePath;
    }

    NSString *urlString = components.string;
    if (!urlString) {
        // TODO: need Exception ？？？
        return nil;
    }

    request.URL = [NSURL URLWithString:urlString];
    double timeSpent = [_easyHandle getTimeoutIntervalSpent];
    request.timeoutInterval = fromRequest.timeoutInterval - timeSpent;
    return request;
}

#pragma mark - Task Processing

- (void)startLoading {
    if (self.internalState == YMURLSessionTaskInternalStateInitial) {
        if (!_originalRequest) {
            // TODO: error
        }

        if (_cachedResponse && [self canRespondFromCacheUsingResponse:_cachedResponse]) {
        } else {
            [self startNewTransferByRequest:_originalRequest];
        }
    }

    if (self.internalState == YMURLSessionTaskInternalStateTransferReady) {
        self.internalState = YMURLSessionTaskInternalStateTransferInProgress;
    }
}

#pragma mark - Notify Delegate

- (void)notifyDelegateAboutReceiveData:(NSData *)data {
    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    if (b.type != YMURLSessionTaskBehaviourTypeTaskDelegate) return;

    id<YMURLSessionDelegate> delegate = _session.delegate;

    BOOL conformsToDataDelegate =
        delegate && [_session.delegate conformsToProtocol:@protocol(YMURLSessionDataDelegate)];
    if (conformsToDataDelegate && [self isKindOfClass:[YMURLSessionTask class]]) {
        [_session.delegateQueue addOperationWithBlock:^{
            id<YMURLSessionDataDelegate> d = (id<YMURLSessionDataDelegate>)self.session.delegate;
            [d YMURLSession:self.session task:self didReceiveData:data];
        }];
    };

    // TODO: Download task
}

- (void)notifyDelegateAboutLoadData:(NSData *)data {
    _responseData = data;
    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    if (b.type != YMURLSessionTaskBehaviourTypeTaskDelegate) return;

    id<YMURLSessionDelegate> delegate = _session.delegate;

    BOOL conformsToDataDelegate =
        delegate && [_session.delegate conformsToProtocol:@protocol(YMURLSessionDataDelegate)];
    if (conformsToDataDelegate && [self isKindOfClass:[YMURLSessionTask class]]) {
        [_session.delegateQueue addOperationWithBlock:^{
            id<YMURLSessionDataDelegate> d = (id<YMURLSessionDataDelegate>)self.session.delegate;
            [d YMURLSession:self.session task:self didReceiveData:data];
        }];
    };
}

- (void)notifyDelegateAboutError:(NSError *)error {
    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    switch (b.type) {
        case YMURLSessionTaskBehaviourTypeTaskDelegate: {
            [_session.delegateQueue addOperationWithBlock:^{
                if (self.state != YMURLSessionTaskStateCompleted) {
                    id<YMURLSessionTaskDelegate> d = (id<YMURLSessionTaskDelegate>)self.session.delegate;
                    if (d && [d respondsToSelector:@selector(YMURLSession:task:didCompleteWithError:)]) {
                        [d YMURLSession:self.session task:self didCompleteWithError:error];
                    }

                    self->_state = YMURLSessionTaskStateCompleted;
                    dispatch_async(self.workQueue, ^{
                        [self.session.taskRegistry removeWithTask:self];
                    });
                }
            }];
        } break;
        case YMURLSessionTaskBehaviourTypeNoDelegate: {
            if (self.state != YMURLSessionTaskStateCompleted) {
                self->_state = YMURLSessionTaskStateCompleted;
                dispatch_async(self.workQueue, ^{
                    [self.session.taskRegistry removeWithTask:self];
                });
            }
        } break;
        case YMURLSessionTaskBehaviourTypeDataHandler: {
            [_session.delegateQueue addOperationWithBlock:^{
                if (self.state != YMURLSessionTaskStateCompleted) {
                    if (b.dataTaskCompeltion) b.dataTaskCompeltion(nil, nil, error);
                    self->_state = YMURLSessionTaskStateCompleted;
                    dispatch_async(self.workQueue, ^{
                        [self.session.taskRegistry removeWithTask:self];
                    });
                }
            }];
        } break;
        case YMURLSessionTaskBehaviourTypeDownloadHandler: {
            [_session.delegateQueue addOperationWithBlock:^{
                if (self.state != YMURLSessionTaskStateCompleted) {
                    if (b.dataTaskCompeltion) b.downloadCompletion(nil, nil, error);
                    self->_state = YMURLSessionTaskStateCompleted;
                    dispatch_async(self.workQueue, ^{
                        [self.session.taskRegistry removeWithTask:self];
                    });
                }
            }];
        } break;
    }
}

- (void)notifyDelegateAboutFinishLoading {
}

- (void)notifyDelegateAboutUploadedDataCount:(int64_t)cout {
}

- (void)notifyDelegateAboutReceiveResponse:(NSHTTPURLResponse *)response {
    _response = response;

    /// TODO: Only cache data tasks:t
    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    if (b.type == YMURLSessionTaskBehaviourTypeTaskDelegate) {
        if (_session && _session.delegate &&
            [_session.delegate respondsToSelector:@selector(YMURLSession:task:didReceiveResponse:completionHandler:)]) {
            [self askDelegateHowToProceedAfterCompleteResponse:response];
        }
    }
}

- (void)askDelegateHowToProceedAfterCompleteResponse:(NSHTTPURLResponse *)response {
    if (self.internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO: Error
    }

    self.internalState = YMURLSessionTaskInternalStateWaitingForResponseHandler;
    [_session.delegateQueue addOperationWithBlock:^{
        id<YMURLSessionDataDelegate> delegate = (id<YMURLSessionDataDelegate>)self.session.delegate;
        [delegate YMURLSession:self.session
                          task:self
            didReceiveResponse:response
             completionHandler:^(YMURLSessionResponseDisposition disposition) {
                 [self didCompleteResponseCallbackWithDisposition:disposition];
             }];
    }];
}

- (void)didCompleteResponseCallbackWithDisposition:(YMURLSessionResponseDisposition)disposition {
    if (self.internalState != YMURLSessionTaskInternalStateWaitingForResponseHandler) {
        // TODO: Error
    }
    switch (disposition) {
        case YMURLSessionResponseCancel: {
            self.internalState = YMURLSessionTaskInternalStateTransferFailed;
            NSError *urlError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [self completeTaskWithError:urlError];
            [self notifyDelegateAboutError:urlError];
        } break;
        case YMURLSessionResponseAllow:
            self.internalState = YMURLSessionTaskInternalStateTransferInProgress;
            break;
    }
}

#pragma mark - EasyHandle Delegate

- (YMEasyHandleAction)didReceiveWithHeaderData:(NSData *)data contentLength:(int64_t)contentLength {
    if (self.internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO: Error
    }

    NSError *error = nil;
    YMTransferState *ts = _transferState;
    YMTransferState *newTS = [ts byAppendingHTTPHeaderLineData:data error:&error];
    if (error) {
        return YMEasyHandleActionAbort;
    }

    self.internalState = YMURLSessionTaskInternalStateTransferInProgress;
    _transferState = newTS;

    if (!ts.isHeaderComplete && newTS.isHeaderComplete) {
        NSHTTPURLResponse *response = newTS.response;
        NSString *contentEncoding = response.allHeaderFields[@"Content-Encoding"];
        // TODO: countOfBytesExpectedToReceive
        if (![contentEncoding isEqualToString:@"identify"]) {
        } else {
        }
        [self didReceiveResponse];
    }

    return YMEasyHandleActionProceed;
}

- (void)didReceiveResponse {
    if (self.internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO: failure
    }
    if (!_transferState.response) {
        // TODO: failure
    }

    YMURLSessionTaskBehaviour *b = [_session behaviourForTask:self];
    if (b.type == YMURLSessionTaskBehaviourTypeTaskDelegate) {
        switch (_transferState.response.statusCode) {
            case 301:
            case 302:
            case 303:
            case 307:
                break;
            default:
                [self notifyDelegateAboutReceiveResponse:_transferState.response];
        }
    }
}

- (YMEasyHandleAction)didReceiveWithData:(NSData *)data {
    if (self.internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO: Error
    }

    NSHTTPURLResponse *response = [self validateHeaderCompleteWithTS:_transferState];
    if (response) _transferState.response = response;
    [self notifyDelegateAboutReceiveData:data];
    self.internalState = YMURLSessionTaskInternalStateTransferInProgress;
    _transferState = [_transferState byAppendingBodyData:data];
    return YMEasyHandleActionProceed;
}

- (NSHTTPURLResponse *)validateHeaderCompleteWithTS:(YMTransferState *)ts {
    if (!ts.isHeaderComplete) {
        return [[NSHTTPURLResponse alloc] initWithURL:ts.url statusCode:200 HTTPVersion:@"HTTP/0.9" headerFields:@{}];
    }
    return nil;
}

- (void)transferCompletedWithError:(NSError *)error {
    if (self.internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO:
        assert(true);
    }

    if (!_currentRequest) {
        // TODO:
        assert(true);
    }

    if (error) {
        self.internalState = YMURLSessionTaskInternalStateTransferFailed;
        [self failWithError:error request:_currentRequest];
        return;
    }

    if (_response) {
        _transferState.response = _response;
    }

    NSHTTPURLResponse *response = _transferState.response;
    if (!response) {
        // TODO: Error
    }

    self.internalState = YMURLSessionTaskInternalStateTransferCompleted;
    NSURLRequest *rr = [self redirectedReqeustForResponse:response fromRequest:_currentRequest];
    if (rr) {
        [self redirectForRequest:rr];
    } else {
        [self completeTask];
    }
}

- (void)fillWriteBuffer:(NSData *)buffer result:(void (^)(YMEasyHandleWriteBufferResult, NSInteger))result {
    if (_internalState != YMURLSessionTaskInternalStateTransferInProgress) {
        // TODO: Error
    }

    id<YMURLSessionTaskBodySource> source = _transferState.requestBodySource;

    if (!source) {
        // TODO: Error
    }

    if (!result) return;

    [source getNextChunkWithLength:buffer.length
                 completionHandler:^(YMBodySourceDataChunk chunk, NSData *_Nullable data) {
                     switch (chunk) {
                         case YMBodySourceDataChunkData: {
                             NSUInteger count = data.length;
                             [self notifyDelegateAboutUploadedDataCount:(int64_t)count];
                             result(YMEasyHandleWriteBufferResultBytes, count);
                         } break;
                         case YMBodySourceDataChunkDone:
                             result(YMEasyHandleWriteBufferResultBytes, 0);
                             break;
                         case YMBodySourceDataChunkRetryLater:
                             result(YMEasyHandleWriteBufferResultPause, -1);
                             break;
                         case YMBodySourceDataChunkError:
                             result(YMEasyHandleWriteBufferResultAbort, -1);
                             break;
                     }
                 }];
}

- (BOOL)seekInputStreamToPosition:(uint64_t)position {
    __block NSInputStream *currentInputStream = nil;

    if (_session.delegate && [_session.delegate conformsToProtocol:@protocol(YMURLSessionTaskDelegate)] &&
        [_session.delegate respondsToSelector:@selector(YMURLSession:task:needNewBodyStream:)]) {
        id<YMURLSessionTaskDelegate> d = (id<YMURLSessionTaskDelegate>)_session.delegate;

        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);

        [d YMURLSession:_session
                         task:self
            needNewBodyStream:^(NSInputStream *_Nullable bodyStream) {
                currentInputStream = bodyStream;
                dispatch_group_leave(group);
            }];
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC);
        dispatch_group_wait(group, timeout);
    }

    if (_originalRequest.URL && currentInputStream) {
        if (self.internalState == YMURLSessionTaskInternalStateTransferInProgress) {
            if ([_transferState.requestBodySource isKindOfClass:[YMBodyStreamSource class]]) {
                BOOL result = [currentInputStream ym_seekToPosition:position];
                if (!result) return false;
                YMDataDrain *drain = [self createTransferBodyDataDrain];
                YMBodyStreamSource *source = [[YMBodyStreamSource alloc] initWithInputStream:currentInputStream];
                YMTransferState *ts = [[YMTransferState alloc] initWithURL:_originalRequest.URL
                                                             bodyDataDrain:drain
                                                                bodySource:source];
                self.internalState = YMURLSessionTaskInternalStateTransferInProgress;
                _transferState = ts;
                return true;
            }
        } else {
            return NO;
        }
    }

    return NO;
}
#pragma mark - Headers Methods

- (NSDictionary *)transformLowercaseKeyForHTTPHeaders:(NSDictionary *)HTTPHeaders {
    if (!HTTPHeaders) return nil;

    NSMutableDictionary *result = @{}.mutableCopy;
    for (NSString *key in [HTTPHeaders allKeys]) {
        result[[key lowercaseString]] = HTTPHeaders[key];
    }
    return [result copy];
}

- (NSArray<NSString *> *)curlHeadersForHTTPHeaders:(NSDictionary *)HTTPHeaders {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *names = [NSMutableSet set];

    for (NSString *key in [HTTPHeaders allKeys]) {
        NSString *name = [key lowercaseString];
        if ([names containsObject:name]) break;
        [names addObject:name];

        NSString *value = HTTPHeaders[key];
        if (value.length == 0) {
            [result addObject:[NSString stringWithFormat:@"%@;", key]];
        } else {
            [result addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
        }
    }

    NSDictionary *curlHeadersToSet = [self curlHeadersToSet];
    for (NSString *key in [curlHeadersToSet allKeys]) {
        NSString *name = [key lowercaseString];
        if ([names containsObject:name]) break;
        [names addObject:name];

        NSString *value = curlHeadersToSet[key];
        if (value.length == 0) {
            [result addObject:[NSString stringWithFormat:@"%@;", key]];
        } else {
            [result addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
        }
    }

    NSArray *curlHeadersToRemove = [self curlHeadersToRemove];
    for (NSString *key in curlHeadersToRemove) {
        NSString *name = [key lowercaseString];
        if ([names containsObject:name]) break;
        [names addObject:name];
        [result addObject:[NSString stringWithFormat:@"%@:", key]];
    }

    return result;
}

- (NSDictionary *)curlHeadersToSet {
    return @{
        @"Connection" : @"keep-alive",
        @"User-Agent" : [self userAgentString],
        @"Accept-Language" : [self acceptLanguageString]
    };
}

- (NSArray *)curlHeadersToRemove {
    if (_knownBody == nil) {
        return @[];
    } else if (_knownBody.type == YMURLSessionTaskBodyTypeNone) {
        return @[];
    }
    return @[ @"Expect" ];
}

- (NSString *)userAgentString {
    // from AFNetworking
    NSString *userAgent = nil;
    userAgent = [NSString
        stringWithFormat:@"%@/%@ (%@; iOS %@; Scale/%0.2f)",
                         [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleExecutableKey]
                             ?: [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleIdentifierKey],
                         [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]
                             ?: [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleVersionKey],
                         [[UIDevice currentDevice] model],
                         [[UIDevice currentDevice] systemVersion],
                         [[UIScreen mainScreen] scale]];

    if (![userAgent canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        NSMutableString *mutableUserAgent = [userAgent mutableCopy];
        if (CFStringTransform((__bridge CFMutableStringRef)(mutableUserAgent),
                              NULL,
                              (__bridge CFStringRef) @"Any-Latin; Latin-ASCII; [:^ASCII:] Remove",
                              false)) {
            userAgent = mutableUserAgent;
        }
    }
    return userAgent;
}

- (NSString *)acceptLanguageString {
    // from AFNetworking
    NSMutableArray *acceptLanguagesComponents = [NSMutableArray array];
    [[NSLocale preferredLanguages] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        float q = 1.0f - (idx * 0.1f);
        [acceptLanguagesComponents addObject:[NSString stringWithFormat:@"%@;q=%0.1g", obj, q]];
        *stop = q <= 0.5f;
    }];
    return [acceptLanguagesComponents componentsJoinedByString:@", "];
}

@end
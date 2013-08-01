//
//  MixpanelController.m
//  Bondsy
//
//  Created by Paul Shapiro on 7/9/13.
//  Copyright (c) 2013 Bondsy. All rights reserved.
//

#import "MixpanelController.h"
#import "MixpanelSerialization.h"

#include <arpa/inet.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

#import <AdSupport/ASIdentifierManager.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "ODIN.h"


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Macros

#define VERSION @"2.0.0"

#ifndef IFT_ETHER
    #define IFT_ETHER 0x6 // ethernet CSMACD
#endif

#ifdef MIXPANEL_LOG
    #define MixpanelLog(...) NSLog(__VA_ARGS__)
    #define MixpanelError(...) NSLog(__VA_ARGS__)
    #define MixpanelWarn(...) NSLog(__VA_ARGS__)
#else
    #define MixpanelLog(...)
    #define MixpanelError(...)
    #define MixpanelWarn(...)
#endif

#ifdef MIXPANEL_DEBUG
    #define MixpanelDebug(...) NSLog(__VA_ARGS__)
#else
    #define MixpanelDebug(...)
#endif


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Constants

NSString *const kMixpanelAPIBaseURL = @"https://api.mixpanel.com";
NSString *const kMixpanelAPITrackPath = @"/track/";
NSString *const kMixpanelAPIEngagePath = @"/engage/";

NSTimeInterval *const kMixpanelDefaultFlushInterval = 25;
int const kMixpanelBatchFragmentSize = 50;

typedef enum {
    MixpanelNetworkRequestDormant,
    MixpanelNetworkRequestInProgress,
    MixpanelNetworkRequestConcluded
} MixpanelNetworkRequestState;

NSString *const MixpanelController_archive_filename_events = @"events";
NSString *const MixpanelController_archive_filename_people = @"people";
NSString *const MixpanelController_archive_filename_properties = @"properties";

NSString *const Mixpanel_JSON_key_apiToken = @"token";
NSString *const Mixpanel_JSON_key_mp_lib = @"mp_lib";
NSString *const Mixpanel_JSON_key_mp_lib_value_iphone = @"iphone";
NSString *const Mixpanel_JSON_key_$lib_version = @"$lib_version";
NSString *const Mixpanel_JSON_key_$app_version = @"$app_version";
NSString *const Mixpanel_JSON_key_$app_release = @"$app_release";
NSString *const Mixpanel_JSON_key_$manufacturer = @"$manufacturer";
NSString *const Mixpanel_JSON_key_$manufacturer_value_Apple = @"Apple";
NSString *const Mixpanel_JSON_key_$os = @"$os";
NSString *const Mixpanel_JSON_key_$os_version = @"$os_version";
NSString *const Mixpanel_JSON_key_$model = @"$model";
NSString *const Mixpanel_JSON_key_mp_device_model = @"mp_device_model";
NSString *const Mixpanel_JSON_key_$screen_height = @"$screen_height";
NSString *const Mixpanel_JSON_key_$screen_width = @"$screen_width";
NSString *const Mixpanel_JSON_key_$wifi = @"$wifi";
NSString *const Mixpanel_JSON_key_$carrier = @"$carrier";
NSString *const Mixpanel_JSON_key_$ios_ifa = @"$ios_ifa";
NSString *const Mixpanel_JSON_key_time = @"time";
NSString *const Mixpanel_JSON_key_distinct_id = @"distinct_id";
NSString *const Mixpanel_JSON_key_$distinct_id = @"$distinct_id";
NSString *const Mixpanel_JSON_key_mp_name_tag = @"mp_name_tag";

NSString *const Mixpanel_JSON_key_event = @"event";
NSString *const Mixpanel_JSON_key_properties = @"properties";

NSString *const Mixpanel_JSON_key_ip = @"ip";
NSString *const Mixpanel_JSON_key_data = @"data";

NSString *const Mixpanel_classString_ASIdentifierManager = @"ASIdentifierManager";

char *const MixpanelController_serial_IO_queue_labelCString = "com.mixpanel.SerialIOQueue";


////////////////////////////////////////////////////////////////////////////////
#pragma mark - C

dispatch_queue_t MixpanelController_serial_IO_queue;


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Interfaces - MixpanelController

@interface MixpanelController ()

// Spec
@property (nonatomic, copy) NSString *apiToken;

// Persisted
@property (nonatomic, strong) NSMutableArray *eventsQueue;
@property (nonatomic, strong) NSMutableArray *peopleQueue;
@property (nonatomic, strong) NSMutableDictionary *superProperties;
@property (nonatomic, copy, readwrite) NSString *distinctId;

// Transient
@property (nonatomic, strong) NSMutableDictionary *eventEssentialProperties;
@property (nonatomic, strong) NSArray *sendingEventsQueueFragment;
@property (nonatomic, strong) NSArray *sendingPeopleQueueFragment;
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
@property (nonatomic, assign) UIBackgroundTaskIdentifier taskId;
#endif

// Runtime
@property (nonatomic, strong) AFHTTPRequestOperation *currentEventsRequestOperation;
@property (nonatomic, strong) AFHTTPRequestOperation *currentPeopleRequestOperation;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic, strong) NSOperationQueue *networkingOperationQueue;
@property (nonatomic, strong) MixpanelSerialization *mixpanelSerializer;
@property (nonatomic, strong, readwrite) MixpanelPeople *people;

@end


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Interfaces - MixpanelPeople

@interface MixpanelPeople ()

@property (nonatomic, unsafe_unretained) MixpanelController *mixpanelController;
@property (nonatomic, strong) NSMutableArray *unidentifiedQueue;
@property (nonatomic, copy) NSString *distinctId;

- (id)initWithMixpanelController:(MixpanelController *)mixpanelController;

@end


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Implementation - MixpanelController

@implementation MixpanelController


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Lifecycle

- (id)initWithToken:(NSString *)apiToken
{
    self = [super init];
    if (self) {
        self.apiToken = apiToken;

        [self setup];
    }
    
    return self;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setup

- (void)setup
{
    [self setupModel];
    [self setupRuntime];
    
    [self startObserving];
    
    [self initiateRuntime];
}

- (void)setupModel
{
    // spec
    self.serverURL = kMixpanelAPIBaseURL;
    self.flushInterval = kMixpanelDefaultFlushInterval;
    self.flushOnDidEnterBackground = YES; // default
    self.showNetworkActivityIndicator = YES;

    // transient
    self.eventEssentialProperties = [self newEventEssentialProperties];
    
    // persisted
    self.eventsQueue = [self newUnarchivedEventsQueue];
    self.peopleQueue = [self newUnarchivedPeopleQueue];
    self.superProperties = [NSMutableDictionary dictionary];
    self.distinctId = [self newDefaultDistinctId];
    
    [self _unarchiveProperties]; // this will overwrite distinctId if properties were previously persisted
}

- (void)setupRuntime
{
    MixpanelController_serial_IO_queue = dispatch_queue_create(MixpanelController_serial_IO_queue_labelCString, NULL);
    self.networkingOperationQueue = [[NSOperationQueue alloc] init];
    
    self.mixpanelSerializer = [[MixpanelSerialization alloc] init];
    self.people = [[MixpanelPeople alloc] initWithMixpanelController:self];
}

- (void)startObserving
{
    [self startObservingApplication];
}

- (void)startObservingApplication
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)] && &UIBackgroundTaskInvalid) {
        self.taskId = UIBackgroundTaskInvalid;
        if (&UIApplicationDidEnterBackgroundNotification) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        }
        if (&UIApplicationWillEnterForegroundNotification) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        }
    }
#endif
}

- (void)initiateRuntime
{
    if (self.eventsQueue.count) { // what was just unarchived
        [self _performFlush]; // recovery/restart immediately
    }
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Teardown

- (void)teardown
{
    [self stopObserving];
    self.delegate = nil;

    MixpanelController_serial_IO_queue = nil;
}

- (void)stopObserving
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p %@>", NSStringFromClass([self class]), self, self.apiToken];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Cache Reads

- (NSMutableArray *)newUnarchivedEventsQueue
{    
    return [self newUnarchivedQueueAtFilePath:[self eventsFilePath]];
}

- (NSMutableArray *)newUnarchivedPeopleQueue
{    
    return [self newUnarchivedQueueAtFilePath:[self peopleFilePath]];
}

- (NSMutableArray *)newUnarchivedQueueAtFilePath:(NSString *)filePath
{
    NSMutableArray *objects = nil;
    @try {
        objects = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        if (objects) {
            objects = [objects mutableCopy];  // stored version not guaranteed to be mutable
        }
        MixpanelDebug(@"%@ unarchived data: %@", self, objects);
    }
    @catch (NSException *exception) {
        NSLog(@"%@ unable to unarchive data, starting fresh", self);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        objects = nil;
    }
    if (!objects) {
        objects = [NSMutableArray array];
    }
    
    return objects;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Events

- (NSMutableDictionary *)newEventEssentialProperties
{
    UIDevice *device = [UIDevice currentDevice];
    NSString *deviceModelString = [self newDeviceModelString];
    NSDictionary *mainBundleInfoDictionary = [[NSBundle mainBundle] infoDictionary];
    CGSize size = [UIScreen mainScreen].bounds.size;
    CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
    CTCarrier *carrier = [networkInfo subscriberCellularProvider];
    
    NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionary];
    [mutableDictionary setObject:self.apiToken forKey:Mixpanel_JSON_key_apiToken];
    [mutableDictionary setValue:Mixpanel_JSON_key_mp_lib_value_iphone forKey:Mixpanel_JSON_key_mp_lib];
    [mutableDictionary setValue:VERSION forKey:Mixpanel_JSON_key_$lib_version];
    [mutableDictionary setValue:[mainBundleInfoDictionary objectForKey:@"CFBundleVersion"] forKey:Mixpanel_JSON_key_$app_version];
    [mutableDictionary setValue:[mainBundleInfoDictionary objectForKey:@"CFBundleShortVersionString"] forKey:Mixpanel_JSON_key_$app_release];
    [mutableDictionary setValue:Mixpanel_JSON_key_$manufacturer_value_Apple forKey:Mixpanel_JSON_key_$manufacturer];
    [mutableDictionary setValue:[device systemName] forKey:Mixpanel_JSON_key_$os];
    [mutableDictionary setValue:[device systemVersion] forKey:Mixpanel_JSON_key_$os_version];
    [mutableDictionary setValue:deviceModelString forKey:Mixpanel_JSON_key_$model];
    [mutableDictionary setValue:deviceModelString forKey:Mixpanel_JSON_key_mp_device_model]; // legacy
    [mutableDictionary setValue:@((int)size.width) forKey:Mixpanel_JSON_key_$screen_width];
    [mutableDictionary setValue:@((int)size.height) forKey:Mixpanel_JSON_key_$screen_height];
    [mutableDictionary setValue:@([self newIsWifiAvailableNumber]) forKey:Mixpanel_JSON_key_$wifi];
    if (carrier.carrierName.length) {
        [mutableDictionary setValue:carrier.carrierName forKey:Mixpanel_JSON_key_$carrier];
    }
    if (NSClassFromString(Mixpanel_classString_ASIdentifierManager)) {
        [mutableDictionary setValue:ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString forKey:Mixpanel_JSON_key_$ios_ifa];
    }
    
    return mutableDictionary;
}

- (NSDictionary *)newEventDictionaryFrom:(NSString *)eventName andProperties:(NSDictionary *)properties
{
    NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionary];
    [mutableDictionary addEntriesFromDictionary:self.eventEssentialProperties];
    [mutableDictionary setObject:@((long)[[NSDate date] timeIntervalSince1970]) forKey:Mixpanel_JSON_key_time];
    if (self.distinctId) {
        [mutableDictionary setObject:self.distinctId forKey:Mixpanel_JSON_key_distinct_id];
    }
    if (self.nameTag) {
        [mutableDictionary setObject:self.nameTag forKey:Mixpanel_JSON_key_mp_name_tag];
    }
    [mutableDictionary addEntriesFromDictionary:self.superProperties];
    if (properties) {
        [mutableDictionary addEntriesFromDictionary:properties];
    }

    [MixpanelSerialization assertDictionaryValidation:mutableDictionary];

    return @
    {
        Mixpanel_JSON_key_event : eventName,
        Mixpanel_JSON_key_properties : mutableDictionary
    };
}

- (NSString *)newDefaultDistinctId
{
    NSString *distinctId = nil;
    if (NSClassFromString(@"ASIdentifierManager")) {
        distinctId = ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString;
    }
    if (!distinctId) {
        distinctId = ODIN1();
    }
    if (!distinctId) {
        NSLog(@"%@ error getting default distinct id: both iOS IFA and ODIN1 failed", self);
    }
    return distinctId;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Networking

- (NSArray *)newEventsFragmentToSend
{
    if ([self.eventsQueue count] > kMixpanelBatchFragmentSize) {
        return [self.eventsQueue subarrayWithRange:NSMakeRange(0, kMixpanelBatchFragmentSize)];
    } else {
        return [NSArray arrayWithArray:self.eventsQueue];
    }
}

- (NSArray *)newPeopleFragmentToSend
{
    if ([self.peopleQueue count] > kMixpanelBatchFragmentSize) {
        return [self.peopleQueue subarrayWithRange:NSMakeRange(0, kMixpanelBatchFragmentSize)];
    } else {
        return [NSArray arrayWithArray:self.peopleQueue];
    }
}

- (NSURL *)newMixpanelAPIBaseURL
{
    return [NSURL URLWithString:kMixpanelAPIBaseURL];
}

- (AFHTTPRequestOperation *)newFlushNetworkRequestOperationWithPath:(NSString *)requestPath andPostBody:(NSString *)postBody success:(void(^)(AFHTTPRequestOperation *op, id responseObject))success failure:(void(^)(AFHTTPRequestOperation *op, NSError *error))failure
{
    AFHTTPClient *client = [[AFHTTPClient alloc] initWithBaseURL:[self newMixpanelAPIBaseURL]];
    NSMutableURLRequest *request = [client requestWithMethod:@"POST" path:requestPath parameters:nil];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [request setHTTPBody:[postBody dataUsingEncoding:NSUTF8StringEncoding]];
    
    AFHTTPRequestOperation *requestOperation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    [requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject)
    {
        success(operation, responseObject);

        [self updateNetworkActivityIndicator];
        [self endBackgroundTaskIfComplete];
    } failure:^(AFHTTPRequestOperation *operation, NSError *error)
    {
        failure(operation, error);
        
        [self updateNetworkActivityIndicator];
        [self endBackgroundTaskIfComplete];
    }];
    
    return requestOperation;
}

- (AFHTTPRequestOperation *)newEventsFlushNetworkRequestOperation
{
    NSString *requestPath = kMixpanelAPITrackPath;
    NSString *base64EncodedSerializedEventsString = [self.mixpanelSerializer newEncodedSerializedStringFrom:self.sendingEventsQueueFragment];
    NSString *postBody = [NSString stringWithFormat:@"%@=%d&%@=%@", Mixpanel_JSON_key_ip, 1, Mixpanel_JSON_key_data, base64EncodedSerializedEventsString];
    
    return [self newFlushNetworkRequestOperationWithPath:requestPath andPostBody:postBody success:^(AFHTTPRequestOperation *op, id responseObject)
    {
        NSString *response = [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding];
        if ([response intValue] == 0) {
            DDLogError(@"Mixpanel events /track/ API error: status code: %d, response: '%@'", op.response.statusCode, response);
        }
        
        [self serialDispatchAsyncBlock:^
        { // must be synced or will get exception of mutating during enumeration
            [self.eventsQueue removeObjectsInArray:self.sendingEventsQueueFragment];
            self.sendingEventsQueueFragment = nil; // must be within the same block
            [self _archiveEvents]; // synchronous
        }];
        self.currentEventsRequestOperation = nil;
    } failure:^(AFHTTPRequestOperation *op, NSError *error)
    {
        DDLogError(@"%@ network failure: %@", self, error);
        
        [self serialDispatchAsyncBlock:^
        { // must be synced or will get exception of mutating during enumeration
            [self _archiveEvents]; // synchronous
        }];
        self.sendingEventsQueueFragment = nil;
        self.currentEventsRequestOperation = nil;
    }];
}

- (AFHTTPRequestOperation *)newPeopleFlushNetworkRequestOperation
{
    NSString *requestPath = kMixpanelAPIEngagePath;
    NSString *base64EncodedSerializedEventsString = [self.mixpanelSerializer newEncodedSerializedStringFrom:self.sendingPeopleQueueFragment];
    NSString *postBody = [NSString stringWithFormat:@"%@=%@", Mixpanel_JSON_key_data, base64EncodedSerializedEventsString];
    
    return [self newFlushNetworkRequestOperationWithPath:requestPath andPostBody:postBody success:^(AFHTTPRequestOperation *op, id responseObject)
    {
        NSString *response = [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding];
        if ([response intValue] == 0) {
            DDLogError(@"Mixpanel events /engage/ API error: status code: %d, response: '%@'", op.response.statusCode, response);
        }
         
        [self serialDispatchAsyncBlock:^
        { // must be synced or will get exception of mutating during enumeration
            [self.peopleQueue removeObjectsInArray:self.sendingPeopleQueueFragment];
            self.sendingPeopleQueueFragment = nil; // must be within the same block
            [self _archivePeople]; // synchronous
        }];
        self.currentPeopleRequestOperation = nil;
    } failure:^(AFHTTPRequestOperation *op, NSError *error)
    {
        DDLogError(@"%@ network failure: %@", self, error);
         
        [self serialDispatchAsyncBlock:^
        { // must be synced or will get exception of mutating during enumeration
            [self _archivePeople]; // synchronous
        }];
        self.sendingPeopleQueueFragment = nil;
        self.currentPeopleRequestOperation = nil;
    }];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Persistence

- (NSString *)newFilePathForData:(NSString *)data
{
    NSString *filename = [NSString stringWithFormat:@"mixpanel-%@-%@.plist", self.apiToken, data];
    return [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject]
            stringByAppendingPathComponent:filename];
}

- (NSString *)eventsFilePath
{
    return [self newFilePathForData:MixpanelController_archive_filename_events];
}

- (NSString *)peopleFilePath
{
    return [self newFilePathForData:MixpanelController_archive_filename_people];
}

- (NSString *)propertiesFilePath
{
    return [self newFilePathForData:MixpanelController_archive_filename_properties];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Runtime

- (NSString *)newDeviceModelString
{
    size_t stringSize;
    sysctlbyname("hw.machine", NULL, &stringSize, NULL, 0);
    char *cString = malloc(stringSize);
    sysctlbyname("hw.machine", cString, &stringSize, NULL, 0);
    NSString *string = [NSString stringWithCString:cString encoding:NSUTF8StringEncoding];
    free(cString);

    return string;
}

- (BOOL)newIsWifiAvailableNumber
{
    struct sockaddr_in sockAddr;
    bzero(&sockAddr, sizeof(sockAddr));
    sockAddr.sin_len = sizeof(sockAddr);
    sockAddr.sin_family = AF_INET;
    
    SCNetworkReachabilityRef nrRef = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&sockAddr);
    SCNetworkReachabilityFlags flags;
    BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(nrRef, &flags);
    if (!didRetrieveFlags) {
        MixpanelWarn(@"%@ unable to fetch the network reachablity flags", self);
    }
    
    CFRelease(nrRef);
    
    if (!didRetrieveFlags || (flags & kSCNetworkReachabilityFlagsReachable) != kSCNetworkReachabilityFlagsReachable) {
        // unable to connect to a network (no signal or airplane mode activated)
        return NO;
    }    
    if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN) {
        // only a cellular network connection is available.
        return NO;
    }
    
    return YES;
}

- (BOOL)isInBackground
{
    BOOL inBg = NO;
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    inBg = [[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground;
#endif
    if (inBg) {
        MixpanelDebug(@"%@ in background", self);
    }
    return inBg;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Factories - Superproperties

- (NSDictionary *)getCurrentSuperProperties
{
    return [self.superProperties copy];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Runtime

- (void)reset
{
    [self serialDispatchAsyncBlock:^
    {
        self.distinctId = [self newDefaultDistinctId];
        self.nameTag = nil;
        self.superProperties = [NSMutableDictionary dictionary];
        
        self.people.distinctId = nil;
        self.people.unidentifiedQueue = [NSMutableArray array];
         
        self.eventsQueue = [NSMutableArray array];
        self.peopleQueue = [NSMutableArray array];
         
        [self _archive];
    }];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Dispatch

- (void)serialDispatchAsyncBlock:(void(^)(void))block
{
    dispatch_async(MixpanelController_serial_IO_queue, block);
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Tracking

- (void)track:(NSString *)event
{
    [self track:event properties:nil];
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties
{
    NSDictionary *eventDictionary = [self newEventDictionaryFrom:event andProperties:properties];
    [self _enqueue:eventDictionary];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Enqueuement

- (void)_enqueue:(NSDictionary *)eventDictionary
{
    [self serialDispatchAsyncBlock:^
    { // synchronized with _archive and _performFlushEntry
        [self.eventsQueue addObject:eventDictionary];
        if ([self isInBackground]) {
            [self _archiveEvents]; // synchronous
        }
    }];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Flush

- (void)_startFlushTimer
{
    [self _stopFlushTimer];
    if (self.flushInterval > 0) {
        dispatch_async(dispatch_get_main_queue(), ^
        { // the timer should be set up on the main thread
            self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.flushInterval target:self selector:@selector(_performFlush) userInfo:nil repeats:YES];
            MixpanelDebug(@"%@ started flush timer: %@", NSStringFromClass([self class]), self.flushTimer);
        });
    }
}

- (void)_stopFlushTimer
{
    if (self.flushTimer) {
        [self.flushTimer invalidate];
        MixpanelDebug(@"%@ stopped flush timer: %@", self, self.flushTimer);
    }
    self.flushTimer = nil;
}

- (void)_performFlush
{
    // If the app is currently in the background but Mixpanel has not requested
    // to run a background task, the flush will be cut short. This can happen
    // when the app forces a flush from within its own background task.
    if ([self isInBackground] && self.taskId == UIBackgroundTaskInvalid) {
        [self _performFlushInBackgroundTask];
        return;
    }

    [self serialDispatchAsyncBlock:^
    { // Synchronized with _enqueue and _archive
        if (self.delegate && [self.delegate respondsToSelector:@selector(mixpanelWillFlush:)]) {
            if (![self.delegate mixpanelWillFlush:self]) {
                MixpanelDebug(@"%@ delegate deferred flush", self);
                return;
            }
        }
        
        // extracting fragments serially on MixpanelController_objects_pool_IO_queue
        [self _flushEvents]; 
        [self _flushPeople];
    }];
}

- (void)_performFlushInBackgroundTask
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    [self serialDispatchAsyncBlock:^
    { // Synchronized with _enqueue and _archive
        if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)] &&
            [[UIApplication sharedApplication] respondsToSelector:@selector(endBackgroundTask:)]) {
            
            self.taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^
            {
                MixpanelDebug(@"%@ flush background task %u cut short", self, self.taskId);
                [self _cancelFlush];
                [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
                self.taskId = UIBackgroundTaskInvalid;
            }];
            
            MixpanelDebug(@"%@ starting flush background task %u", self, self.taskId);
            [self _performFlush];
            
            // connection callbacks end this task by calling endBackgroundTaskIfComplete
        }
    }];
#endif
}

- (void)_flushEvents
{
    if (self.sendingEventsQueueFragment) {
        DDLogError(@"Asked to %@ while sendingEventsQueueFragment already exists. Bailing.", NSStringFromSelector(_cmd));
        return;
    }
    if (self.currentEventsRequestOperation) {
        MixpanelDebug(@"Asked to %@ when currentEventsRequestOperation already existed.", NSStringFromSelector(_cmd));
        return;
    }
    if (!self.eventsQueue.count) { // this is fairly typical
        return;
    }
    
    self.sendingEventsQueueFragment = [self newEventsFragmentToSend];
    [self.networkingOperationQueue addOperationWithBlock:^
    {
        self.currentEventsRequestOperation = [self newEventsFlushNetworkRequestOperation];
        [self.networkingOperationQueue addOperation:self.currentEventsRequestOperation];

        [self updateNetworkActivityIndicator];
    }];
}

- (void)_flushPeople
{
    if (self.sendingPeopleQueueFragment) {
        DDLogError(@"Asked to %@ while sendingPeopleQueueFragment already exists. Bailing.", NSStringFromSelector(_cmd));
        return;
    }
    if (self.currentPeopleRequestOperation) {
        MixpanelDebug(@"Asked to %@ when currentPeopleRequestOperation already existed.", NSStringFromSelector(_cmd));
        return;
    }
    if (!self.peopleQueue.count) { // this is fairly typical
        return;
    }
    
    self.sendingPeopleQueueFragment = [self newPeopleFragmentToSend];
    [self.networkingOperationQueue addOperationWithBlock:^
    {
        self.currentPeopleRequestOperation = [self newPeopleFlushNetworkRequestOperation];
        [self.networkingOperationQueue addOperation:self.currentPeopleRequestOperation];

        [self updateNetworkActivityIndicator];
    }];
}
                   
- (void)_cancelFlush
{
    if (self.currentEventsRequestOperation == nil) {
        MixpanelDebug(@"%@ no events connection to cancel", self);
    } else {
        MixpanelDebug(@"%@ cancelling events connection", self);
        [self.currentEventsRequestOperation cancel];
        self.currentEventsRequestOperation = nil;
    }
    if (self.currentPeopleRequestOperation == nil) {
        MixpanelDebug(@"%@ no people connection to cancel", self);
    } else {
        MixpanelDebug(@"%@ cancelling people connection", self);
        [self.currentPeopleRequestOperation cancel];
        self.currentPeopleRequestOperation = nil;
    }
}

- (void)updateNetworkActivityIndicator
{
    BOOL visible = self.showNetworkActivityIndicator && (self.currentEventsRequestOperation || self.currentPeopleRequestOperation);
    
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:visible];
}

- (void)endBackgroundTaskIfComplete
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    // if the os version allows background tasks, the app supports them, and we're in one, end it
    if (&UIBackgroundTaskInvalid
        && [[UIApplication sharedApplication] respondsToSelector:@selector(endBackgroundTask:)]
        && self.taskId != UIBackgroundTaskInvalid
        && self.currentEventsRequestOperation == nil
        && self.currentPeopleRequestOperation == nil) {
        MixpanelDebug(@"%@ ending flush background task %u", self, self.taskId);
        [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
        self.taskId = UIBackgroundTaskInvalid;
    }
#endif
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Archive

- (void)_archive
{
    [self serialDispatchAsyncBlock:^
    {
        [self _archiveEvents];
        [self _archivePeople];
        [self _archiveProperties];
    }];
}

- (void)_archiveEvents
{
    NSString *filePath = [self eventsFilePath];
    if (![NSKeyedArchiver archiveRootObject:self.eventsQueue toFile:filePath]) {
        NSLog(@"%@ unable to archive events data", self);
    }
}

- (void)_archivePeople
{
    NSString *filePath = [self peopleFilePath];
    if (![NSKeyedArchiver archiveRootObject:self.peopleQueue toFile:filePath]) {
        NSLog(@"%@ unable to archive people data", self);
    }
}

- (void)_archiveProperties
{
    NSString *filePath = [self propertiesFilePath];
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    [properties setValue:self.distinctId forKey:@"distinctId"];
    [properties setValue:self.nameTag forKey:@"nameTag"];
    [properties setValue:self.superProperties forKey:@"superProperties"];
    [properties setValue:self.people.distinctId forKey:@"peopleDistinctId"];
    [properties setValue:self.people.unidentifiedQueue forKey:@"peopleUnidentifiedQueue"];
    MixpanelDebug(@"%@ archiving properties data to %@: %@", self, filePath, properties);
    if (![NSKeyedArchiver archiveRootObject:properties toFile:filePath]) {
        NSLog(@"%@ unable to archive properties data", self);
    }
}

- (void)_unarchiveProperties
{
    NSString *filePath = [self propertiesFilePath];
    NSDictionary *properties = nil;
    @try {
        properties = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        MixpanelDebug(@"%@ unarchived properties data: %@", self, properties);
    }
    @catch (NSException *exception) {
        NSLog(@"%@ unable to unarchive properties data, starting fresh", self);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    }
    if (properties) {
        self.distinctId = [properties objectForKey:@"distinctId"];
        self.nameTag = [properties objectForKey:@"nameTag"];
        self.superProperties = [properties objectForKey:@"superProperties"];
        self.people.distinctId = [properties objectForKey:@"peopleDistinctId"];
        self.people.unidentifiedQueue = [properties objectForKey:@"peopleUnidentifiedQueue"];
    }
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - People/Identification

- (void)identify:(NSString *)distinctId
{
    [self serialDispatchAsyncBlock:^
    {
        self.distinctId = distinctId;
        self.people.distinctId = distinctId;
        if (distinctId != nil && distinctId.length != 0 && self.people.unidentifiedQueue.count > 0) {
            for (NSMutableDictionary *r in self.people.unidentifiedQueue) {
                [r setObject:distinctId forKey:Mixpanel_JSON_key_$distinct_id];
                [self.peopleQueue addObject:r];
            }
            [self.people.unidentifiedQueue removeAllObjects];
        }
        if ([self isInBackground]) {
            [self _archiveProperties];
            [self _archivePeople];
        }
    }];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives - Super properties

- (void)registerSuperProperties:(NSDictionary *)properties
{
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self serialDispatchAsyncBlock:^
    {
        [self.superProperties addEntriesFromDictionary:properties];
        if ([self isInBackground]) {
            [self _archiveProperties];
        }
    }];
}

- (void)registerSuperPropertiesOnce:(NSDictionary *)properties
{
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self serialDispatchAsyncBlock:^
    {
        for (NSString *key in properties) {
            if ([self.superProperties objectForKey:key] == nil) {
                [self.superProperties setObject:[properties objectForKey:key] forKey:key];
            }
        }
        if ([self isInBackground]) {
            [self _archiveProperties];
        }
    }];
}

- (void)registerSuperPropertiesOnce:(NSDictionary *)properties defaultValue:(id)defaultValue
{
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self serialDispatchAsyncBlock:^
    {
        for (NSString *key in properties) {
            id value = [self.superProperties objectForKey:key];
            if (value == nil || [value isEqual:defaultValue]) {
                [self.superProperties setObject:[properties objectForKey:key] forKey:key];
            }
        }
        if ([self isInBackground]) {
            [self _archiveProperties];
        }
    }];
}

- (void)unregisterSuperProperty:(NSString *)propertyName
{
    [self serialDispatchAsyncBlock:^
    {
        if ([self.superProperties objectForKey:propertyName] != nil) {
            [self.superProperties removeObjectForKey:propertyName];
            if ([self isInBackground]) {
                [self _archiveProperties];
            }
        }
    }];
}

- (void)clearSuperProperties
{
    [self serialDispatchAsyncBlock:^
    {
        [self.superProperties removeAllObjects];
        if ([self isInBackground]) {
            [self _archiveProperties];
        }
    }];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Delegation - Application

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application did become active", self);
    [self _startFlushTimer];
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application will resign active", self);
    [self _stopFlushTimer];
}

- (void)applicationDidEnterBackground:(NSNotificationCenter *)notification
{
    MixpanelDebug(@"%@ did enter background", self);
    
    if (self.flushOnDidEnterBackground) {
        [self _performFlushInBackgroundTask];
    }
}

- (void)applicationWillEnterForeground:(NSNotificationCenter *)notification
{
    MixpanelDebug(@"%@ will enter foreground", self);
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    if (&UIBackgroundTaskInvalid) {
        if (self.taskId != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
        }
        self.taskId = UIBackgroundTaskInvalid;
    }
    [self _cancelFlush];
    [self updateNetworkActivityIndicator];
#endif
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application will terminate", self);
    [self _archive];
}

@end


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Implementation - MixpanelPeople

@interface MixpanelPeople ()

@property (nonatomic, strong) NSDictionary *deviceInfoProperties;

@end

@implementation MixpanelPeople


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Lifecycle

- (id)initWithMixpanelController:(MixpanelController *)mixpanelController
{
    self = [self init];
    if (self) {
        self.mixpanelController = mixpanelController;

        [self setup];
    }

    return self;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setup

- (void)setup
{
    self.unidentifiedQueue = [NSMutableArray array];
    self.deviceInfoProperties = [self newDeviceInfoProperties];

    [self startObserving];
}

- (void)startObserving
{
    
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Teardown

- (void)teardown
{
    self.mixpanelController = nil;
    self.distinctId = nil;
    self.unidentifiedQueue = nil;
    self.deviceInfoProperties = nil;

    [self stopObserving];
}

- (void)stopObserving
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors

- (NSDictionary *)newDeviceInfoProperties
{
    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *mainBundleInfoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *deviceModelString = [self.mixpanelController newDeviceModelString];

    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    [properties setValue:deviceModelString forKey:@"$ios_device_model"];
    [properties setValue:[device systemVersion] forKey:@"$ios_version"];
    [properties setValue:[mainBundleInfoDictionary objectForKey:@"CFBundleVersion"] forKey:@"$ios_app_version"];
    [properties setValue:[mainBundleInfoDictionary objectForKey:@"CFBundleShortVersionString"] forKey:@"$ios_app_release"];
    if (NSClassFromString(@"ASIdentifierManager")) {
        [properties setValue:ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString forKey:@"$ios_ifa"];
    }
    return [NSDictionary dictionaryWithDictionary:properties];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MixpanelPeople: %p %@>", self, self.mixpanelController.apiToken];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imperatives

- (void)addPushDeviceToken:(NSData *)deviceToken
{
    const unsigned char *buffer = (const unsigned char *)[deviceToken bytes];
    if (!buffer) {
        return;
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
    for (NSUInteger i = 0; i < deviceToken.length; i++) {
        [hex appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)buffer[i]]];
    }
    NSArray *tokens = [NSArray arrayWithObject:[NSString stringWithString:hex]];
    NSDictionary *properties = [NSDictionary dictionaryWithObject:tokens forKey:@"$ios_devices"];
    [self addPeopleRecordToQueueWithAction:@"$union" andProperties:properties];
}

- (void)set:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self addPeopleRecordToQueueWithAction:@"$set" andProperties:properties];
}

- (void)set:(NSString *)property to:(id)object
{
    NSAssert(property != nil, @"property must not be nil");
    NSAssert(object != nil, @"object must not be nil");
    if (property == nil || object == nil) {
        return;
    }
    [self set:[NSDictionary dictionaryWithObject:object forKey:property]];
}

- (void)setOnce:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self addPeopleRecordToQueueWithAction:@"$set_once" andProperties:properties];
}

- (void)increment:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    for (id v in [properties allValues]) {
        NSAssert([v isKindOfClass:[NSNumber class]],
                 @"%@ increment property values should be NSNumber. found: %@", self, v);
    }
    [self addPeopleRecordToQueueWithAction:@"$add" andProperties:properties];
}

- (void)increment:(NSString *)property by:(NSNumber *)amount
{
    NSAssert(property != nil, @"property must not be nil");
    NSAssert(amount != nil, @"amount must not be nil");
    if (property == nil || amount == nil) {
        return;
    }
    [self increment:[NSDictionary dictionaryWithObject:amount forKey:property]];
}

- (void)append:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [MixpanelSerialization assertDictionaryValidation:properties];
    [self addPeopleRecordToQueueWithAction:@"$append" andProperties:properties];
}

- (void)trackCharge:(NSNumber *)amount
{
    [self trackCharge:amount withProperties:nil];
}

- (void)trackCharge:(NSNumber *)amount withProperties:(NSDictionary *)properties
{
    NSAssert(amount != nil, @"amount must not be nil");
    if (amount != nil) {
        NSMutableDictionary *txn = [NSMutableDictionary dictionaryWithObjectsAndKeys:amount, @"$amount", [NSDate date], @"$time", nil];
        if (properties) {
            [txn addEntriesFromDictionary:properties];
        }
        [self append:[NSDictionary dictionaryWithObject:txn forKey:@"$transactions"]];
    }
}

- (void)clearCharges
{
    [self set:[NSDictionary dictionaryWithObject:[NSArray array] forKey:@"$transactions"]];
}

- (void)deleteUser
{
    [self addPeopleRecordToQueueWithAction:@"$delete" andProperties:[NSDictionary dictionary]];
}

- (void)addPeopleRecordToQueueWithAction:(NSString *)action andProperties:(NSDictionary *)properties
{
    @synchronized(self) {
        
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        
        [r setObject:self.mixpanelController.apiToken forKey:@"$token"];
        
        if (![r objectForKey:@"$time"]) {
            // milliseconds unix timestamp
            NSNumber *time = [NSNumber numberWithUnsignedLongLong:(uint64_t)([[NSDate date] timeIntervalSince1970] * 1000)];
            [r setObject:time forKey:@"$time"];
        }
        
        if ([action isEqualToString:@"$set"] || [action isEqualToString:@"$set_once"]) {
            [p addEntriesFromDictionary:self.deviceInfoProperties];
        }
        
        [p addEntriesFromDictionary:properties];
        
        [r setObject:[NSDictionary dictionaryWithDictionary:p] forKey:action];
        
        if (self.distinctId) {
            [r setObject:self.distinctId forKey:@"$distinct_id"];
            MixpanelLog(@"%@ queueing people record: %@", self.mixpanelController, r);
            [self.mixpanelController.peopleQueue addObject:r];
        } else {
            MixpanelLog(@"%@ queueing unidentified people record: %@", self.mixpanelController, r);
            [self.unidentifiedQueue addObject:r];
        }
        if ([self.mixpanelController isInBackground]) {
            [self.mixpanelController _archivePeople];
        }
    }
}

@end
//
//  MixpanelController.h
//  Bondsy
//
//  Created by Paul Shapiro on 7/9/13.
//  Copyright (c) 2013 Bondsy. All rights reserved.
//

#import <Foundation/Foundation.h>

@class MixpanelPeople;
@protocol MixpanelDelegate;


////////////////////////////////////////////////////////////////////////////////

@interface MixpanelController : NSObject

- (id)initWithToken:(NSString *)apiToken;

- (void)track:(NSString *)event;
- (void)track:(NSString *)event properties:(NSDictionary *)properties;

- (void)identify:(NSString *)distinctId;

- (void)registerSuperProperties:(NSDictionary *)properties;
- (void)registerSuperPropertiesOnce:(NSDictionary *)properties;
- (void)registerSuperPropertiesOnce:(NSDictionary *)properties defaultValue:(id)defaultValue;
- (void)unregisterSuperProperty:(NSString *)propertyName;
- (void)clearSuperProperties;

- (void)reset;

// readwrite
@property (nonatomic, copy) NSString *serverURL;
@property (nonatomic) NSUInteger flushInterval;
@property (nonatomic) BOOL flushOnDidEnterBackground;
@property (nonatomic) BOOL showNetworkActivityIndicator;
@property (nonatomic, copy) NSString *nameTag;
@property (nonatomic, unsafe_unretained) id<MixpanelDelegate> delegate; // allows fine grain control over uploading (optional)

// read-only
@property (nonatomic, strong, readonly) MixpanelPeople *people;
@property (nonatomic, copy, readonly) NSString *distinctId;

@property (nonatomic, readonly, getter = getCurrentSuperProperties) NSDictionary *currentSuperProperties;

@end


////////////////////////////////////////////////////////////////////////////////

@interface MixpanelPeople : NSObject

- (void)addPushDeviceToken:(NSData *)deviceToken;
- (void)set:(NSDictionary *)properties;
- (void)set:(NSString *)property to:(id)object;
- (void)setOnce:(NSDictionary *)properties;
- (void)increment:(NSDictionary *)properties;
- (void)increment:(NSString *)property by:(NSNumber *)amount;
- (void)append:(NSDictionary *)properties;
- (void)trackCharge:(NSNumber *)amount;
- (void)trackCharge:(NSNumber *)amount withProperties:(NSDictionary *)properties;
- (void)clearCharges;
- (void)deleteUser;

@end


////////////////////////////////////////////////////////////////////////////////

@protocol MixpanelDelegate <NSObject>

@optional
- (BOOL)mixpanelWillFlush:(MixpanelController *)mixpanel;

@end
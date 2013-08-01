//
//  MixpanelSerialization.m
//  Bondsy
//
//  Created by Paul Shapiro on 7/10/13.
//  Copyright (c) 2013 Bondsy. All rights reserved.
//

#import "MixpanelSerialization.h"
#import "MPCJSONDataSerializer.h"
#import "NSData+MPBase64.h"



////////////////////////////////////////////////////////////////////////////////
#pragma mark - Macros



////////////////////////////////////////////////////////////////////////////////
#pragma mark - Constants



////////////////////////////////////////////////////////////////////////////////
#pragma mark - C



////////////////////////////////////////////////////////////////////////////////
#pragma mark - Interface

@interface MixpanelSerialization ()

@property (nonatomic, strong) NSDateFormatter *dateFormatter;

@end


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Implementation

@implementation MixpanelSerialization


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Lifecycle

- (id)init
{
    self = [super init];
    if (self) {
        [self setup];
    }
    
    return self;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setup

- (void)setup
{
    [self setupDateFormatter];
    
    [self startObserving];
}

- (void)setupDateFormatter
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    self.dateFormatter = formatter;
}

- (void)startObserving
{
    
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Teardown

- (void)teardown
{
    [self stopObserving];
}

- (void)stopObserving
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors - Transforms

- (NSString *)newEncodedSerializedStringFrom:(NSArray *)array
{
    NSString *b64String = @"";
    NSData *data = [self JSONSerializeObject:array];
    if (data) {
        b64String = [data mp_base64EncodedString];
        b64String = (id)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)b64String, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8));
    }
    
    return b64String;
}

- (NSData *)JSONSerializeObject:(id)obj
{
    id coercedObj = [self JSONSerializableObjectForObject:obj];
    
    MPCJSONDataSerializer *serializer = [MPCJSONDataSerializer serializer];
    NSError *error = nil;
    NSData *data = nil;
    @try {
        data = [serializer serializeObject:coercedObj error:&error];
    }
    @catch (NSException *exception) {
        NSLog(@"%@ exception encoding api data: %@", self, exception);
    }
    if (error) {
        NSLog(@"%@ error encoding api data: %@", self, error);
    }
    return data;
}

- (id)JSONSerializableObjectForObject:(id)obj
{
    // valid json types
    if ([obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSNull class]]) {
        return obj;
    }
    
    // recurse on containers
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id i in obj) {
            [a addObject:[self JSONSerializableObjectForObject:i]];
        }
        return [NSArray arrayWithArray:a];
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (id key in obj) {
            NSString *stringKey;
            if (![key isKindOfClass:[NSString class]]) {
                stringKey = [key description];
                NSLog(@"%@ warning: property keys should be strings. got: %@. coercing to: %@", self, [key class], stringKey);
            } else {
                stringKey = [NSString stringWithString:key];
            }
            id v = [self JSONSerializableObjectForObject:[obj objectForKey:key]];
            [d setObject:v forKey:stringKey];
        }
        return [NSDictionary dictionaryWithDictionary:d];
    }
    
    // some common cases
    if ([obj isKindOfClass:[NSDate class]]) {
        NSString *s = [self.dateFormatter stringFromDate:obj];
        return s;
    } else if ([obj isKindOfClass:[NSURL class]]) {
        return [obj absoluteString];
    }
    
    // default to sending the object's description
    NSString *s = [obj description];
    NSLog(@"%@ warning: property values should be valid json types. got: %@. coercing to: %@", self, [obj class], s);
    return s;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class

+ (void)assertDictionaryValidation:(NSDictionary *)eventDictionary
{
    // PS: Is this really necessary? It's probably somewhat expensive.
    for (id key in eventDictionary) {
        id value = [eventDictionary objectForKey:key];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
        BOOL keyIsValidClass = [key isKindOfClass:[NSString class]];
        NSAssert(keyIsValidClass, @"%@ property keys must be NSString. got: %@ %@", self, [key class], key);
#pragma clang diagnostic pop
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
        BOOL valueIsValidClass = [value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSNull class]] ||
        [value isKindOfClass:[NSArray class]] ||
        [value isKindOfClass:[NSDictionary class]] ||
        [value isKindOfClass:[NSDate class]] ||
        [value isKindOfClass:[NSURL class]];
        NSAssert(valueIsValidClass, @"%@ property values must be NSString, NSNumber, NSNull, NSArray, NSDictionary, NSDate or NSURL. got: %@ %@", self, [value class], value);
#pragma clang diagnostic pop
    }
}

@end

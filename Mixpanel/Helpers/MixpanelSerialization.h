//
//  MixpanelSerialization.h
//  Bondsy
//
//  Created by Paul Shapiro on 7/10/13.
//  Copyright (c) 2013 Bondsy. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MixpanelSerialization : NSObject

- (NSString *)newEncodedSerializedStringFrom:(NSArray *)array;

+ (void)assertDictionaryValidation:(NSDictionary *)eventDictionary;

@end

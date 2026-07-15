#ifndef NeoNuiUtils_h
#define NeoNuiUtils_h

#ifdef DEBUG_MODE
#define TLog( s, ... ) NSLog( s, ##__VA_ARGS__ )
#else
#define TLog( s, ... )
#endif

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NeoNuiUtils : NSObject

@property (readonly) void* nui_utils;

+ (instancetype)get_instance;

- (const char *)nui_utils_refresh_apikey:(const char *)apikey
                                     Url:(const char *)url;

- (const char *)nui_uitls_get_version;

- (const char *)nui_uitls_get_app_code;

+ (NSString *)replenishHardwareInfo:(NSString *)params;

+ (NSDictionary *)hardwareInfo;

+ (NSString*)getDeviceType;

+ (NSString *)getDeviceModel;

+ (NSString*)getDeviceName;

@end

NS_ASSUME_NONNULL_END

#endif /* NeoNuiUtils_h */


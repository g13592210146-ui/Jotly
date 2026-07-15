//
//  NeoNuiTts.h
//  nuisdk
//
//  Created by zhouguangdong on 2019/12/21.
//  Copyright © 2019年 zhouguangdong. All rights reserved.
//

#ifndef NeoNuiTts_h
#define NeoNuiTts_h

#ifdef DEBUG_MODE
#define TLog( s, ... ) NSLog( s, ##__VA_ARGS__ )
#else
#define TLog( s, ... )
#endif

#import <Foundation/Foundation.h>
#import "NeoNuiCode.h"


enum NuiSdkTtsEvent {
  TTS_EVENT_START = 0,
  TTS_EVENT_END = 1,
  TTS_EVENT_CANCEL = 2,
  TTS_EVENT_PAUSE = 3,
  TTS_EVENT_RESUME = 4,
  TTS_EVENT_ERROR = 5,
  TTS_EVENT_CACEH_START = 6,
  TTS_EVENT_CACEH_END = 7,
  TTS_EVENT_CACEH_CANCEL = 8,
  TTS_EVENT_CACEH_DELETE = 9,
  TTS_EVENT_CACEH_ERROR = 10,
  TTS_EVENT_FONT_EVENT_START = 11,
  TTS_EVENT_FONT_DOWNLOAD = 12,
  TTS_EVENT_FONT_END = 13,
  TTS_EVENT_FONT_PAUSE = 14,
  TTS_EVENT_FONT_RESUME = 15,
  TTS_EVENT_FONT_CANCEL = 16,
  TTS_EVENT_FONT_ERROR = 17
};

typedef enum NuiSdkTtsEvent NuiSdkTtsEvent;

@protocol NeoNuiTtsDelegate <NSObject>
@optional
- (void)onNuiTtsEventCallback:(NuiSdkTtsEvent)event taskId:(char*)taskid code:(int)code;
- (void)onNuiTtsUserdataCallback:(char*)info infoLen:(int)info_len buffer:(char*)buffer len:(int)len taskId:(char*)task_id;
- (void)onNuiTtsVolumeCallback:(int)volume taskId:(char*)task_id;
- (void)onNuiTtsLogTrackCallback:(NuiSdkLogLevel)level
                      logMessage:(const char *)log;
@end

@interface NeoNuiTts : NSObject
@property (readonly) void* nui_tts_sdk;
@property (nonatomic,weak) id<NeoNuiTtsDelegate> delegate;

+ (instancetype)get_instance;

-(int) nui_tts_initialize:(const char *)parameters
                 logLevel:(NuiSdkLogLevel)level
                  saveLog:(BOOL)save_log;

-(int) nui_tts_release;

-(int) nui_tts_play:(const char *)priority
             taskId:(const char *)taskid
               text:(const char *)text;

-(int) nui_tts_cancel:(const char *)taskid;

-(int) nui_tts_pause;

-(int) nui_tts_resume;

-(int) nui_tts_set_param:(const char *)param
                   value:(const char *)value;

-(const char *) nui_tts_get_param:(const char *)param;

-(int) nui_tts_get_num_of_chars:(const char *)param;
@end

#endif /* NeoNuiTts_h */

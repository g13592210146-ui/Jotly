#ifndef NeoNui_h
#define NeoNui_h

#ifdef DEBUG_MODE
#define TLog( s, ... ) NSLog( s, ##__VA_ARGS__ )
#else
#define TLog( s, ... )
#endif

#import <Foundation/Foundation.h>
#import "NeoNuiCode.h"

typedef int NuiResultCode;

enum NuiAudioState {
    STATE_OPEN,
    STATE_PAUSE,
    STATE_CLOSE,
};

enum NuiFunMode {
  kFuncModeAsp = 0x00000001,
  kFuncModeVad = 0x00000010,
  kFuncModeKws = 0x00000100,
  kFuncModeAsr = 0x00001000,
  kFuncModeEnc = 0x00010000,
  kFuncModeOu = 0x00100000,
  kFuncModeFull = 0x11111111,
};

enum NuiAudioExtraEvent {
  AudioRmsChanged,
};

enum NuiCallbackEvent {
  EVENT_VAD_START,
  EVENT_VAD_TIMEOUT,
  EVENT_VAD_END,
  EVENT_WUW,
  EVENT_WUW_TRUSTED,
  EVENT_WUW_CONFIRMED,
  EVENT_WUW_REJECTED,
  EVENT_WUW_END,
  EVENT_ASR_PARTIAL_RESULT,
  EVENT_ASR_RESULT,
  EVENT_ASR_ERROR, // 10
  EVENT_DIALOG_ERROR,
  EVENT_ONESHOT_TIMEOUT,
  EVENT_DIALOG_RESULT,
  EVENT_WUW_HINT,
  EVENT_VPR_RESULT,
  EVENT_TEXT2ACTION_DIALOG_RESULT,
  EVENT_TEXT2ACTION_ERROR,
  EVENT_ATTR_RESULT,
  EVENT_MIC_ERROR,
  EVENT_DIALOG_EX, // 20
  EVENT_WUW_ERROR,
  EVENT_BEFORE_CONNECTION,
  EVENT_SENTENCE_START,
  EVENT_SENTENCE_END,
  EVENT_SENTENCE_SEMANTICS,
  EVENT_RESULT_TRANSLATED,
  EVENT_TRANSCRIBER_COMPLETE,
  EVENT_FILE_TRANS_CONNECTED,
  EVENT_FILE_TRANS_UPLOADED,
  EVENT_FILE_TRANS_RESULT, // 30
  EVENT_FILE_TRANS_UPLOAD_PROGRESS,
  EVENT_TRANSCRIBER_STARTED,
  EVENT_ASR_STARTED,
  EVENT_FILE_TRANS_QUERY_RESULT,
  EVENT_WUW_START,
  EVENT_WUW_DATA,
  EVENT_ASR_TTS_DATA,
  EVENT_ASR_TTS_START,
  EVENT_ASR_TTS_COMPLETE,
  EVENT_RESULT_TRANSLATED_END,
  EVENT_ASR_WARN, // 41
};

enum NuiVadMode {
  MODE_VAD,
  MODE_P2T,
  MODE_KWS,
  MODE_PARALLEL,
  MODE_KWS2PARALLEL,
  MODE_AUTO_CONTINUAL,
  MODE_KWS_CONTINUAL,
  MODE_KWS2TALK,
  MODE_ONLY_KWS
};

enum ServiceType {
  SERVICE_TYPE_NONE = -1,
  SERVICE_TYPE_ASR = 0, // SpeechRecognizer
  SERVICE_TYPE_TIANGONG_ASSISTANT = 1,
  SERVICE_TYPE_DIALOG_ASSISTANT = 2, //DialogAssistant
  SERVICE_TYPE_VIRTUAL_ASSISTANT = 3,  //TiangongV4
  SERVICE_TYPE_SPEECH_TRANSCRIBER = 4  //SpeechTranscriber
};

enum NuiSdkVprEvent {
  EVENT_VPR_NONE,
  EVENT_VPR_REGISTER_START,
  EVENT_VPR_REGISTER_DONE,
  EVENT_VPR_REGISTER_FAILED,
  EVENT_VPR_UPDATE_START,
  EVENT_VPR_UPDATE_DONE,
  EVENT_VPR_UPDATE_FAIL,
  EVENT_VPR_DELETE_DONE,
  EVENT_VPR_DELETE_FAIL
};

typedef enum NuiSdkVprEvent NuiSdkVprEvent;
typedef enum NuiAudioState NuiAudioState;
typedef enum NuiCallbackEvent NuiCallbackEvent;
typedef enum NuiCallbackEvent NuiCallbackEvent;
typedef enum NuiVadMode NuiVadMode;

@protocol NeoNuiSdkDelegate <NSObject>
@optional
-(int) onNuiNeedAudioData:(char *)audioData length:(int)len;
-(void) onNuiAudioStateChanged:(NuiAudioState)state;
-(void) onNuiEventCallback:(NuiCallbackEvent)nuiEvent
                          dialog:(long)dialog
                          kwsResult:(const char *)wuw
                          asrResult:(const char *)asr_result
                          ifFinish:(BOOL)finish
                          retCode:(int)code;
-(void) onNuiRmsChanged:(float) rms;
-(void) onNuiAssistEventCallback:(NuiCallbackEvent)nuiEvent
                            info:(char*)info
                         infoLen:(int)info_len
                          buffer:(char*)buffer
                             len:(int)len;
-(void) onNuiLogTrackCallback:(NuiSdkLogLevel)level
                   logMessage:(const char *)log;

-(void) onFileTransEventCallback:(NuiCallbackEvent)nuiEvent
                                 asrResult:(const char *)asr_result
                                 taskId:(const char *)task_id
                                 ifFinish:(BOOL)finish
                                 retCode:(int)code;
-(void) onFileTransLogTrackCallback:(NuiSdkLogLevel)level
                         logMessage:(const char *)log;
@end

@interface NeoNui : NSObject

@property (readonly) void* nui_sdk;
@property (nonatomic,weak) id<NeoNuiSdkDelegate> delegate;

+ (instancetype)get_instance;

//Initialize API
-(NuiResultCode) nui_initialize:(const char *)parameters
                    logLevel:(NuiSdkLogLevel)level
                    saveLog:(BOOL)save_log;
//Release API
-(NuiResultCode) nui_release;

//Dialog API
-(NuiResultCode) nui_dialog_start:(NuiVadMode)vad_mode
                      dialogParam:(const char *)dialog_params;
-(NuiResultCode) nui_dialog_cancel:(BOOL)force;
-(NuiResultCode) nui_dialog_resume;

//Text to Action API
-(NuiResultCode) nui_dialog_text2action:(const char *)text
                                Context:(const char *)context
                            isNewDialog:(BOOL)is_new_dialog
                           dialogParams:(const char *)dialog_params;
-(NuiResultCode) nui_dialog_text2action_cancel;

//File Transcriber API
-(NuiResultCode) nui_file_trans_start:(const char *)params
                               taskId:(char*)task_id;
-(NuiResultCode) nui_file_trans_cancel:(const char*)task_id;
-(NuiResultCode) nui_file_trans_query:(const char*)task_id;

//Set parameter API
-(NuiResultCode) nui_set_param:(const char *)para
                         Value:(const char *)value;
-(NuiResultCode) nui_set_params:(const char *)params;

-(const char *) nui_get_param:(const char *)param;

-(NuiResultCode) nui_update_audio_data:(const char *)data
                                    Len:(int)length
                             FirstPack:(BOOL)first_pack;
-(const char*) nui_get_version;
-(const char*) nui_get_all_response;

#ifdef NUI_VPR
//Voice Print Recognition API
-(NuiResultCode) nui_vpr_register_user:(const char*)service_id
                               groupId:(const char * )group_id
                                userId:(const char * )user_id;
-(NuiResultCode) nui_vpr_update_user:(const char* )service_id
                             groupId:(const char * )group_id
                              userId:(const char * )user_id;
-(NuiResultCode) nui_vpr_delete_user:(const char* )service_id
                             groupId:(const char * )group_id
                              userId:(const char * )user_id;
-(NuiResultCode) nui_vpr_enable;
-(NuiResultCode) nui_vpr_disable;
-(NuiResultCode) nui_vpr_register_cancel;
#endif
@end

#endif

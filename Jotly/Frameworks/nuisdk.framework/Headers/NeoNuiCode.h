//
//  NeoNuiCode.h
//  
//
//  Created by zhouguangdong on 2021/3/11.
//

#ifndef NeoNuiCode_h
#define NeoNuiCode_h

enum NuiSdkLogLevel {
  NUI_LOG_LEVEL_VERBOSE,
  NUI_LOG_LEVEL_DEBUG,
  NUI_LOG_LEVEL_INFO,
  NUI_LOG_LEVEL_WARNING,
  NUI_LOG_LEVEL_ERROR,
  NUI_LOG_LEVEL_NONE,
};
typedef enum NuiSdkLogLevel NuiSdkLogLevel;

typedef int NuiResultCode;
#define SUCCESS (0)
//legacy, not required handle
#define DEFAULT_ERROR (240999) //default err value.

//config or params invalid
#define NUI_CONFIG_INVALID (240001) //Config or file invalid.
#define ILLEGAL_PARAM (240002) //parmeters illegal.
#define ILLEGAL_INIT_PARAM (240003) //initialize with illegal parameters.
#define NECESSARY_PARAM_LACK (240004) //lack of necessaray parameters.
#define NULL_PARAM_ERROR (240005) //parameters with null pointer or empty content.
#define NULL_LISTENER_ERROR (240006) //no listener for callback set.
#define NULL_DIALOG_ERROR (240007) //no dialog created.
#define NULL_ENGINE_ERROR (240008) //no dialog engine created.
#define ILLEGAL_DATA (240009) //transfer illegal audio or video data.
#define ILLEGAL_WORD_LIST (2400010) //word list format error
//state invalid
#define ILLEGAL_REENTRANT (240010) //happen when call from async callback or sdk already exit.
#define SDK_NOT_INIT (240011) //call apis when sdk not initialized.
#define SDK_ALREADY_INIT (240012) //call initialize if already initialized.
#define DIALOG_INVALID_STATE (240013) //dialog state machine error.
#define STATE_INVALID (240014) //asr engine state machine error.
#define ILLEGAL_FUNC_CALL (240015) //some function is not supposed to call on some working mode.

//system call fail
#define MEM_ALLOC_ERROR (240020) //alloc or new object fail.
#define FILE_ACCESS_FAIL (240021) //access file fail.
#define CREATE_DIR_ERROR (240022) //create directory fail.

//nui call fail
#define CREATE_NUI_ERROR (240030) //create dialog engine fail.
#define TEXT_DIALOG_START_FAIL (240031) //start text to action fail.
#define TEXT_DIALOG_CANCEL_FAIL (240032) //cancel text to action fail.
#define WUW_DUPLICATE (240033) //set duplicated wake words for dynamic keywords.

//cei call fail
#define CEI_INIT_FAIL (240040) //init cei engine fail.
#define CEI_SET_PARAM_FAIL (240041) //cei set parameters fail.
#define CEI_COMPILE_GRAMMAR_FAIL (240042) //cei compile grammar fail.
#define CEI_STOP_FAIL (240043) //cei stop fail.
#define CEI_CANCEL_FAIL (240044) //cei cancel fail.
#define CEI_UNLOAD_KWS_FAIL (240045) //cei unload kws fail.
#define GET_WUW_ERROR (240046) //cei get wakeup word fail.
#define CEI_CHECK_BIN_FAIL (240047) //check resource bin file fail

//audio manager
#define SELECT_RECORDER_ERROR (240050) //select recorder fail.
#define UPDATE_AUDIO_ERROR (240051) //update audio fail) usually push audio more than wanted.
#define MIC_ERROR (240052) //get audio data fail continually for 2 senconds.

//nls error
#define CREATE_DA_REQUEST_ERROR (240060) //create dialog assistant fail.
#define START_DA_REQUEST_ERROR (240061) //start dialog assistant fail.
#define DEFAULT_NLS_ERROR (240062) //default network error.
#define SSL_ERROR (240063) //ssl new fail.
#define SSL_CONNECT_FAILED (240064) //ssl connect fail.
#define HTTP_CONNECT_FAILED (240065) //http connect fail.
#define DNS_FAILED (240066) //DNS fail.
#define CONNECT_FAILED (240067) //connect socket fail.
#define SERVER_NOT_ACCESS (240068) //server responce status bad.
#define SOCKET_CLOSED (240069) //socket closed.
#define AUTH_FAILED (240070) //authentication fail.
#define HTTPDNS_FAILED (240071) //connect fail when use http dns.
#define HTTP_SEND_FAILED (240072)
#define HTTP_RECEIVE_FAILED (240073)
#define HTTP_RESPONSE_ERROR (240074)
#define HTTP_SERVER_ERROR (240075)

//function call timeout
#define ENGINE_INIT_TIMEOUT (240080) //init engine timeout.
#define SET_PARAM_TIMEOUT (240081) //set parameters timeout.
#define SET_WUW_TIMEOUT (240082) //set wakeup word timeout.
#define SELECT_RECORDER_TIMEOUT (240083) //select recorder timeout.
#define STOP_TIMEOUT (240084) //stop dialog timeout.
#define ASR_ENGINE_STOP_TIMEOUT (240085) //asr engine stop timeout.
#define UNLOAD_DYNAMIC_WUW_TIMEOUT (240086) //unload dynamic wakeup word timeout.
#define ADD_DYNAMIC_WUW_TIMEOUT (240087) //add dynamic wakeup word timeout.
#define HANDLE_API_TIMEOUT (240088)
#define CHECK_ASSET_TIMEOUT (240089) //check asset bin file timeout
//network timeout
#define UPDATE_CONTEXT_TIMEOUT (240090) //update context timeout.
#define CONNECTION_TIMEOUT (240091) //connect to server timeout.
#define PARTIAL_ASR_TIMEOUT (240092) //get partial asr result timeout.
#define ASR_TIMEOUT (240093) //get final asr result timeout.
#define DIALOG_TIMEOUT (240094) //get dialog result timeout.
#define WWV_TIMEOUT (240095) //get wake word verification result timeout.
//legacy
#define WAIT_TIMEOUT (240100) //legacy definition.

#ifdef NUI_VIDEO_MANAGER
#define SELECT_CAMERA_TIMEOUT (240101)
#define SELECT_CAMERA_ERROR (240102)
#endif
#ifdef NUI_SENSOR_MANAGER
#define SELECT_SENSOR_TIMEOUT (240103)
#define SELECT_SENSOR_ERROR (240104)
#endif
#ifdef NUI_INCLUDE_VPR
#define VPR_ARGS_INVALID (240110)
#define VPR_REG_TIMEOUT (240111)
#define VPR_STATE_INVALID (240112)
#define VPR_UPDATE_TIMEOUT (240113)
#define VPR_DELETE_TIMEOUT (240114)
#define VPR_CANCEL_TIMEOUT (240115)
#endif

#define RING_BUF_WRITE_FAIL (240120)
#define AUDIO_PROCESS_THREAD_BLOCK (240121)
#define PERFORMANCE_FILEOVER (240130)

#define RESAMPLE_ERR (240140)
#define FILE_TRANS_TASK_LIMIT (240150)
#define FILE_TRANS_ENCODER_FAIL (140151)

#define THREAD_CREATE_FAILD (240200)
#define SERVER_ERR_SILENT_SPEECH (40010007)

#endif /* NeoNuiCode_h */

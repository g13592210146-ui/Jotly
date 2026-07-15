//
//  NeoNuiStreamInputTts.h
//  nuisdk
//
//  Created by lengjiayi on 2024/4/17.
//  Copyright © 2024 zhouguangdong. All rights reserved.
//

#ifndef StreamInputTts_h
#define StreamInputTts_h

#import <Foundation/Foundation.h>
#import "NeoNuiCode.h"

enum StreamInputTtsCallbackEvent {
    TTS_EVENT_SYNTHESIS_STARTED = 0,
    TTS_EVENT_SENTENCE_BEGIN = 1,
    TTS_EVENT_SENTENCE_SYNTHESIS = 2,
    TTS_EVENT_SENTENCE_END = 3,
    TTS_EVENT_SYNTHESIS_COMPLETE = 4,
    TTS_EVENT_TASK_FAILED = 5
};

typedef enum StreamInputTtsCallbackEvent StreamInputTtsCallbackEvent;

@protocol StreamInputTtsDelegate <NSObject>
@optional
/**
 * 事件回调
 * @param event 回调事件，参见如下事件列表。
 * @param taskid 请求的任务ID，每次调用一个新ID。
 * @param sessionId 请求的会话ID。
 * @param ret_code 参见错误码，出现TTS_EVENT_ERROR事件时有效，可查阅xxxxx。
 * @param error_msg 当产生错误码时，返回错误信息。
 * @param timestamp 时间戳信息。
 * @param all_response 返回的完整json格式信息。
 */
- (void)onStreamInputTtsEventCallback:(StreamInputTtsCallbackEvent)event taskId:(char*)taskid
                            sessionId:(char*)sessionId ret_code:(int)ret_code
                            error_msg:(char*)error_msg timestamp:(char*)timestamp all_response:(char*)all_response;
/**
 * 当合成数据时，此回调被连续调用，App需要在回调中获得合成的音频数据
 * @param buffer 合成的语音数据
 * @param len 合成的语音长度
 */
- (void)onStreamInputTtsDataCallback:(char*)buffer len:(int)len;

- (void)onStreamInputTtsLogTrackCallback:(NuiSdkLogLevel)level
                              logMessage:(const char *)log;
@end


@interface StreamInputTts : NSObject
@property (nonatomic,weak) id<StreamInputTtsDelegate> delegate;

+ (instancetype)get_instance;

/**
 * 与服务端完成建链，并开始流式语音合成任务
 * @param ticket json string形式的鉴权参数，参见下方说明或接口说明：xxxxx
 * @param parameters json string形式的初始化配置参数，参见下方说明或接口说明：xxxxx
 * @param sessionId 会话ID，可传入32个字节的uuid，或传入空内容由SDK自动生成。
 * @param logLevel log打印级别，值越小打印越多。
 * @param saveLog 是否保存log为文件，存储目录为ticket中的debug_path字段值。
 * @return：参见错误码：https://help.aliyun.com/document_detail/459864.html。
 */
- (int) startStreamInputTts:(const char *)ticket parameters:(const char *)parameters
                  sessionId:(const char *)sessionId logLevel:(NuiSdkLogLevel)logLevel
                    saveLog:(BOOL)saveLog;

/**
 * 与服务端完成建链，并开始单向流式语音合成(长文本语音合成)任务，同步接口
 * @param ticket json string形式的鉴权参数，参见下方说明或接口说明：xxxxx
 * @param parameters json string形式的初始化配置参数，参见下方说明或接口说明：xxxxx
 * @param text 待合成文本
 * @param sessionId 会话ID，可传入32个字节的uuid，或传入空内容由SDK自动生成。
 * @param logLevel log打印级别，值越小打印越多。
 * @param saveLog 是否保存log为文件，存储目录为ticket中的debug_path字段值。
 * @return：参见错误码：https://help.aliyun.com/document_detail/459864.html。
 */
- (int) playStreamInputTts:(const char *)ticket parameters:(const char *)parameters
                      text:(const char*)text sessionId:(const char *)sessionId
                  logLevel:(NuiSdkLogLevel)logLevel saveLog:(BOOL)saveLog;

/**
 * 与服务端完成建链，并开始单向流式语音合成(长文本语音合成)任务，异步接口
 * @param ticket json string形式的鉴权参数，参见下方说明或接口说明：xxxxx
 * @param parameters json string形式的初始化配置参数，参见下方说明或接口说明：xxxxx
 * @param text 待合成文本
 * @param sessionId 会话ID，可传入32个字节的uuid，或传入空内容由SDK自动生成。
 * @param logLevel log打印级别，值越小打印越多。
 * @param saveLog 是否保存log为文件，存储目录为ticket中的debug_path字段值。
 * @return：参见错误码：https://help.aliyun.com/document_detail/459864.html。
 */
- (int) asyncPlayStreamInputTts:(const char *)ticket parameters:(const char *)parameters
                           text:(const char*)text sessionId:(const char *)sessionId
                       logLevel:(NuiSdkLogLevel)logLevel saveLog:(BOOL)saveLog;

/**
 * 以流式的方式发送文本
 * @param text 从大模型当中生成的流式文本
 * @return：参见错误码:https://help.aliyun.com/document_detail/459864.html。
 */
- (int) sendStreamInputTts:(const char *)text;

/**
 * 结束合成任务，通知服务端流入文本数据发送完毕，阻塞等待服务端处理完成，并返回所有合成音频。阻塞超时可以通过start接口中的complete_waiting_ms设置
 * @return：参见错误码:https://help.aliyun.com/document_detail/459864.html。
 */
- (int) stopStreamInputTts;

/**
 * 结束合成任务，通知服务端流入文本数据发送完毕，不等待而是立即返回，同时回调继续返回剩余内容
 * @return：参见错误码:https://help.aliyun.com/document_detail/459864.html。
 */
- (int) asyncStopStreamInputTts;

/**
 * 立即停止合成任务，不会有任何回调返回
 * @return：参见错误码:https://help.aliyun.com/document_detail/459864.html。
 */
- (int) cancelStreamInputTts;

/**
 * 手动释放合成任务
 */
- (int) releaseStreamInputTts;

@end

#endif /* NeoNuiStreamInputTts_h */

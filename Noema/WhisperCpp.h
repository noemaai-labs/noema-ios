#ifndef WhisperCpp_h
#define WhisperCpp_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight Objective-C++ bridge over whisper.cpp. Loads a ggml `.bin`
/// model, runs `whisper_full` on a float sample buffer, and exposes segment
/// text with timestamps.
///
/// The underlying implementation is compiled only when the `NOEMA_WHISPER_CPP`
/// preprocessor flag is defined and the `whisper.h` header is available.
/// Without those, the init methods return `nil` and `transcribeSamples…`
/// returns `NO` with a descriptive `NSError`.
@interface NoemaWhisperCppSegment : NSObject
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, assign, readonly) NSTimeInterval startTime;
@property (nonatomic, assign, readonly) NSTimeInterval endTime;
- (instancetype)initWithText:(NSString *)text
                   startTime:(NSTimeInterval)start
                     endTime:(NSTimeInterval)end;
@end

@interface NoemaWhisperCpp : NSObject

/// Loads a ggml `.bin` Whisper model. Returns `nil` if the file cannot be
/// opened or if the shim is disabled at build time (see `NOEMA_WHISPER_CPP`).
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

/// Blocking transcription. `samples` must be 16 kHz mono Float32 PCM.
/// `language` is a two-letter code or `nil` for auto-detection.
/// The `partialHandler` is invoked on a background queue as segments arrive.
/// The `completionHandler` runs once, on the same queue, with the final result.
- (BOOL)transcribeSamples:(const float *)samples
                   length:(NSUInteger)length
                 language:(nullable NSString *)language
                translate:(BOOL)translate
           partialHandler:(nullable void (^ NS_SWIFT_SENDABLE)(NSString *partial))partialHandler
                segments:(NSArray<NoemaWhisperCppSegment *> * __nullable * __nullable)segmentsOut
                fullText:(NSString * __nullable * __nullable)fullTextOut
                    error:(NSError **)error;

/// Requests cancellation of an in-flight transcription.
- (void)cancel;

/// Returns `YES` if compiled with a usable whisper.cpp backend.
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END

#endif /* WhisperCpp_h */

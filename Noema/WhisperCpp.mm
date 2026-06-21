#import "WhisperCpp.h"

#if __has_include(<whisper/whisper.h>)
#import <whisper/whisper.h>
#define NOEMA_WHISPER_CPP_ENABLED 1
#elif __has_include("whisper.h")
#import "whisper.h"
#define NOEMA_WHISPER_CPP_ENABLED 1
#else
#define NOEMA_WHISPER_CPP_ENABLED 0
#endif

@implementation NoemaWhisperCppSegment

- (instancetype)initWithText:(NSString *)text
                   startTime:(NSTimeInterval)start
                     endTime:(NSTimeInterval)end {
    if ((self = [super init])) {
        _text = [text copy];
        _startTime = start;
        _endTime = end;
    }
    return self;
}

@end

#if NOEMA_WHISPER_CPP_ENABLED

@implementation NoemaWhisperCpp {
    struct whisper_context *_ctx;
    volatile BOOL _cancelled;
}

+ (BOOL)isAvailable { return YES; }

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
    if ((self = [super init])) {
        struct whisper_context_params params = whisper_context_default_params();
        #ifdef WHISPER_USE_COREML
        params.use_gpu = true;
        #endif
        _ctx = whisper_init_from_file_with_params([modelPath fileSystemRepresentation], params);
        if (_ctx == NULL) {
            if (error) {
                *error = [NSError errorWithDomain:@"NoemaWhisperCpp" code:1
                                         userInfo:@{ NSLocalizedDescriptionKey: @"Failed to initialize whisper.cpp context" }];
            }
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_ctx != NULL) {
        whisper_free(_ctx);
        _ctx = NULL;
    }
}

- (void)cancel {
    _cancelled = YES;
}

static bool NoemaWhisperCppShouldAbort(void *user_data) {
    NoemaWhisperCpp *self = (__bridge NoemaWhisperCpp *)user_data;
    return self->_cancelled;
}

typedef struct {
    __unsafe_unretained NoemaWhisperCpp *owner;
    void (^partial)(NSString *);
} NoemaWhisperCppCallbackCtx;

static void NoemaWhisperCppSegmentCallback(struct whisper_context *ctx,
                                          struct whisper_state *state,
                                          int n_new,
                                          void *user_data) {
    NoemaWhisperCppCallbackCtx *cb = (NoemaWhisperCppCallbackCtx *)user_data;
    if (cb == NULL || cb->partial == nil) return;
    int total = whisper_full_n_segments(ctx);
    if (total <= 0) return;
    NSMutableString *accum = [NSMutableString string];
    for (int i = 0; i < total; ++i) {
        const char *txt = whisper_full_get_segment_text(ctx, i);
        if (txt != NULL) {
            if (accum.length > 0) [accum appendString:@" "];
            [accum appendString:[NSString stringWithUTF8String:txt]];
        }
    }
    if (accum.length > 0) cb->partial(accum);
}

- (BOOL)transcribeSamples:(const float *)samples
                   length:(NSUInteger)length
                 language:(nullable NSString *)language
                translate:(BOOL)translate
           partialHandler:(nullable void (^)(NSString *))partialHandler
                segments:(NSArray<NoemaWhisperCppSegment *> * __nullable * __nullable)segmentsOut
                fullText:(NSString * __nullable * __nullable)fullTextOut
                    error:(NSError **)error {
    if (_ctx == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"NoemaWhisperCpp" code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"whisper.cpp context not loaded" }];
        }
        return NO;
    }
    _cancelled = NO;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.translate = translate;
    params.no_context = true;
    params.single_segment = false;
    params.suppress_blank = true;
    params.n_threads = (int)MAX(1, [[NSProcessInfo processInfo] activeProcessorCount] - 1);

    const char *langCStr = NULL;
    if (language.length > 0) {
        langCStr = [language UTF8String];
    }
    params.language = langCStr;

    NoemaWhisperCppCallbackCtx cbctx;
    cbctx.owner = self;
    cbctx.partial = partialHandler;
    params.new_segment_callback = NoemaWhisperCppSegmentCallback;
    params.new_segment_callback_user_data = &cbctx;
    params.encoder_begin_callback = NULL;
    params.abort_callback = NoemaWhisperCppShouldAbort;
    params.abort_callback_user_data = (__bridge void *)self;

    int rc = whisper_full(_ctx, params, samples, (int)length);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"NoemaWhisperCpp" code:rc
                                     userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"whisper_full failed (%d)", rc] }];
        }
        return NO;
    }

    int n = whisper_full_n_segments(_ctx);
    NSMutableArray<NoemaWhisperCppSegment *> *segs = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, n)];
    NSMutableString *full = [NSMutableString string];
    for (int i = 0; i < n; ++i) {
        const char *txt = whisper_full_get_segment_text(_ctx, i);
        int64_t t0 = whisper_full_get_segment_t0(_ctx, i);
        int64_t t1 = whisper_full_get_segment_t1(_ctx, i);
        NSString *ns = txt != NULL ? [NSString stringWithUTF8String:txt] : @"";
        [segs addObject:[[NoemaWhisperCppSegment alloc] initWithText:ns
                                                           startTime:(NSTimeInterval)t0 / 100.0
                                                             endTime:(NSTimeInterval)t1 / 100.0]];
        if (full.length > 0) [full appendString:@" "];
        [full appendString:ns];
    }

    if (segmentsOut != NULL) *segmentsOut = [segs copy];
    if (fullTextOut != NULL) *fullTextOut = [full copy];
    return YES;
}

@end

#else

@implementation NoemaWhisperCpp

+ (BOOL)isAvailable { return NO; }

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"NoemaWhisperCpp" code:-1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"whisper.cpp is not linked in this build." }];
    }
    return nil;
}

- (void)cancel {}

- (BOOL)transcribeSamples:(const float *)samples
                   length:(NSUInteger)length
                 language:(nullable NSString *)language
                translate:(BOOL)translate
           partialHandler:(nullable void (^)(NSString *))partialHandler
                segments:(NSArray<NoemaWhisperCppSegment *> * __nullable * __nullable)segmentsOut
                fullText:(NSString * __nullable * __nullable)fullTextOut
                    error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"NoemaWhisperCpp" code:-1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"whisper.cpp is not linked in this build." }];
    }
    return NO;
}

@end

#endif

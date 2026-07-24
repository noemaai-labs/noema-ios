#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LlamaEmbedder : NSObject
- (instancetype)initWithModelPath:(NSString *)modelPath
                          threads:(int)threads
                       nGpuLayers:(int)nGpuLayers
                    contextLength:(int)contextLength
                       poolingType:(int)poolingType;

- (BOOL)isReady;
- (int)dimension;
- (int)countTokens:(NSString *)text;
// Writes one pooled row per input in order. rowStride is measured in floats.
- (BOOL)embedTexts:(NSArray<NSString *> *)texts
         intoBuffer:(float *)buffer
          rowStride:(int)rowStride;
- (void)unload;
@end

NS_ASSUME_NONNULL_END

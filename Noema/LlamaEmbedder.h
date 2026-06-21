// LlamaEmbedder.h
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
- (BOOL)embedText:(NSString *)text intoBuffer:(float *)buffer length:(int)length; // returns YES on success
- (void)unload;
@end

NS_ASSUME_NONNULL_END


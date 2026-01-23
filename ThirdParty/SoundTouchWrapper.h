#import <Foundation/Foundation.h>

@interface STWrapper : NSObject

- (instancetype)initWithSampleRate:(double)sampleRate channels:(int)channels;

- (void)setTempo:(float)tempo;
- (void)setPitchSemitones:(float)pitch;
- (unsigned int)processSamples:(const float *)inBuffer
                     numSamples:(unsigned int)numSamples
                      outBuffer:(float *)outBuffer
             outBufferCapacity:(unsigned int)outCapacity;

- (unsigned int)flushToBuffer:(float *)outBuffer
            outBufferCapacity:(unsigned int)outCapacity;

- (void)clear;

@end

#import "SoundTouchWrapper.h"
#include "SoundTouch.h"

using namespace soundtouch;

@interface STWrapper () {
    SoundTouch *_st;
    int _channels;
}
@end

@implementation STWrapper

- (instancetype)initWithSampleRate:(double)sampleRate channels:(int)channels {
    if ((self = [super init])) {
        _channels = channels;

        _st = new SoundTouch();
        _st->setSampleRate((uint)sampleRate);
        _st->setChannels((uint)channels);

        _st->setTempo(1.0f);
        _st->setPitchSemiTones(0.0f);
    }
    return self;
}

- (void)dealloc {
    delete _st;
}

- (void)setTempo:(float)tempoFactor {
    _st->setTempo(tempoFactor);
}

- (void)setPitchSemitones:(float)semitones {
    _st->setPitchSemiTones(semitones);
}

- (NSUInteger)processSamples:(const float *)inBuffer
                 numSamples:(NSUInteger)numSamples
                  outBuffer:(float *)outBuffer
           outBufferCapacity:(NSUInteger)outCapacity {

    if (numSamples == 0) return 0;

    //soundTouch expects frames, not total samples
    uint numFrames = (uint)(numSamples / _channels);

    _st->putSamples(inBuffer, numFrames);

    uint receivedFrames = _st->receiveSamples(outBuffer, (uint)(outCapacity / _channels));

    return (NSUInteger)(receivedFrames * _channels);
}

- (NSUInteger)flushToBuffer:(float *)outBuffer
           outBufferCapacity:(NSUInteger)outCapacity {

    _st->flush();
    uint receivedFrames = _st->receiveSamples(outBuffer, (uint)(outCapacity / _channels));

    return (NSUInteger)(receivedFrames * _channels);
}

- (void)clear {
    _st->clear();
}

@end

/*
 Copyright (c) 2009, OpenEmu Team


 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "GBAGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OEGBASystemResponderClient.h"
#import <OpenGL/gl.h>

#include "libsnes.hpp"
#include "Sound.h"
#include "Cheats.h"

@interface GBAGameCore () <OEGBASystemResponderClient>
{
    uint16_t *videoBuffer;
    int videoWidth, videoHeight;
    int16_t pad[1][10];
    NSString *romName;
    double sampleRate;
}

@end

NSUInteger GBAEmulatorValues[] = { SNES_DEVICE_ID_JOYPAD_UP, SNES_DEVICE_ID_JOYPAD_DOWN, SNES_DEVICE_ID_JOYPAD_LEFT, SNES_DEVICE_ID_JOYPAD_RIGHT, SNES_DEVICE_ID_JOYPAD_A, SNES_DEVICE_ID_JOYPAD_B, SNES_DEVICE_ID_JOYPAD_L, SNES_DEVICE_ID_JOYPAD_R, SNES_DEVICE_ID_JOYPAD_START, SNES_DEVICE_ID_JOYPAD_SELECT };
NSString *GBAEmulatorKeys[] = { @"Joypad@ Up", @"Joypad@ Down", @"Joypad@ Left", @"Joypad@ Right", @"Joypad@ A", @"Joypad@ B", @"Joypad@ L", @"Joypad@ R", @"Joypad@ Start", @"Joypad@ Select" };

static GBAGameCore *_current;

@implementation GBAGameCore

static void video_callback(const uint16_t *data, unsigned width, unsigned height)
{
    GET_CURRENT_AND_RETURN();

    // Normally our pitch is 2048 bytes.
    int stride = 256;
    // If we have an interlaced mode, pitch is 1024 bytes.
    if(height == 240 || height == 478)
        stride = 240;

    current->videoWidth  = width;
    current->videoHeight = height;

    dispatch_queue_t the_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_apply(height, the_queue, ^(size_t y){
        const uint16_t *src = data + y * stride;
        uint16_t *dst = current->videoBuffer + y * 240;

        memcpy(dst, src, sizeof(uint16_t)*width);
    });
}

// TODO implement systemDrawScreen here

void systemOnWriteDataToSoundBuffer(int16_t *finalWave, int length)
{
    GET_CURRENT_AND_RETURN();

    [[current ringBufferAtIndex:0] write:finalWave maxLength:2*length];
}

static void input_poll_callback(void)
{
	//NSLog(@"poll callback");
}

static int16_t input_state_callback(bool port, unsigned device, unsigned index, unsigned devid)
{
    GET_CURRENT_AND_RETURN(0);

    //NSLog(@"polled input: port: %d device: %d id: %d", port, device, devid);

	if(port == SNES_PORT_1 & device == SNES_DEVICE_JOYPAD)
        return current->pad[0][devid];
    else if(port == SNES_PORT_2 & device == SNES_DEVICE_JOYPAD)
        return current->pad[1][devid];

    return 0;
}

static bool environment_callback(unsigned cmd, void *data)
{
    GET_CURRENT_AND_RETURN(false);

    switch(cmd)
    {
        case SNES_ENVIRONMENT_SET_TIMING :
        {
            snes_system_timing *t = (snes_system_timing*)data;
            current->frameInterval = t->fps;
            current->sampleRate    = t->sample_rate;
            return true;
        }
        case SNES_ENVIRONMENT_GET_FULLPATH :
        {
            //*(const char**)data = (const char*)current->romName;
            *(const char**)data = [current->romName cStringUsingEncoding:NSUTF8StringEncoding];
            NSLog(@"Environ FULLPATH: \"%@\"\n", current->romName);
            break;
        }
        default :
            NSLog(@"Environ UNSUPPORTED (#%u)!\n", cmd);
            return false;
    }

    return true;
}

static void loadSaveFile(const char *path, int type)
{
    FILE *file = fopen(path, "rb");
    if(file == NULL) return;

    size_t size = snes_get_memory_size(type);
    uint8_t *data = snes_get_memory_data(type);

    if(size == 0 || !data)
    {
        fclose(file);
        return;
    }

    int rc = fread(data, sizeof(uint8_t), size, file);
    if(rc != size)
    {
        NSLog(@"Couldn't load save file.");
    }

    NSLog(@"Loaded save file: %s", path);

    fclose(file);
}

static void writeSaveFile(const char* path, int type)
{
    size_t size = snes_get_memory_size(type);
    uint8_t *data = snes_get_memory_data(type);

    if(data && size > 0)
    {
        FILE *file = fopen(path, "wb");
        if(file != NULL)
        {
            NSLog(@"Saving state %s. Size: %d bytes.", path, (int)size);
            if(fwrite(data, sizeof(uint8_t), size, file) != size)
                NSLog(@"Did not save state properly.");
            fclose(file);
        }
    }
}

- (oneway void)didPushGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player;
{
    pad[player-1][GBAEmulatorValues[button]] = 1;
}

- (oneway void)didReleaseGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player;
{
    pad[player-1][GBAEmulatorValues[button]] = 0;
}

- (id)init
{
    if((self = [super init]))
    {
        videoBuffer = (uint16_t *)malloc(240 * 160 * 2);
    }
	
	_current = self;

	return self;
}

#pragma mark Exectuion

- (void)executeFrame
{
    [self executeFrameSkippingFrame:NO];
}

- (void)executeFrameSkippingFrame:(BOOL)skip
{
    snes_run();
}

- (BOOL)loadFileAtPath:(NSString *)path
{
	memset(pad, 0, sizeof(int16_t) * 10);

    uint8_t *data;
    unsigned size;
    romName = [path copy];

    //load cart, read bytes, get length
    NSData *dataObj = [NSData dataWithContentsOfFile:[romName stringByStandardizingPath]];
    if(dataObj == nil) return false;

    size = [dataObj length];
    data = (uint8_t *)[dataObj bytes];

    //remove copier header, if it exists
    //ssif((size & 0x7fff) == 512) memmove(data, data + 512, size -= 512);

    //memory.copy(data, size);
    snes_set_environment(environment_callback);
	snes_init();
	
    snes_set_video_refresh(video_callback);
    snes_set_input_poll(input_poll_callback);
    snes_set_input_state(input_state_callback);
	
    if(snes_load_cartridge_normal(NULL, data, size))
    {
        NSString *path = romName;
        NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];

        NSString *batterySavesDirectory = [self batterySavesDirectoryPath];

        //        if((batterySavesDirectory != nil) && ![batterySavesDirectory isEqualToString:@""])
        if([batterySavesDirectory length] != 0)
        {
            [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

            NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

            loadSaveFile([filePath UTF8String], SNES_MEMORY_CARTRIDGE_RAM);
        }

        snes_set_controller_port_device(SNES_PORT_1, SNES_DEVICE_JOYPAD);
        //snes_set_controller_port_device(SNES_PORT_2, SNES_DEVICE_NONE);

        //snes_get_region();

        soundSetSampleRate(sampleRate);

        snes_run();

        return YES;
    }

    return NO;
}

#pragma mark Video
- (const void *)videoBuffer
{
    return videoBuffer;
}

- (OEIntRect)screenRect
{
    // hope this handles hires :/
    return OEIntRectMake(0, 0, videoWidth, videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(240, 160);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(3, 2);
}

- (void)resetEmulation
{
    snes_reset();
}

- (void)stopEmulation
{
    NSString *path = romName;
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];

    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];

    if([batterySavesDirectory length] != 0)
    {

        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

        NSLog(@"Trying to save SRAM");

        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

        writeSaveFile([filePath UTF8String], SNES_MEMORY_CARTRIDGE_RAM);
    }

    NSLog(@"snes term");
    //snes_unload_cartridge();
    snes_term();
    [super stopEmulation];
}

- (void)dealloc
{
    free(videoBuffer);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_SHORT_1_5_5_5_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB5;
}

- (double)audioSampleRate
{
    return sampleRate ? sampleRate : 32000;
}

- (NSTimeInterval)frameInterval
{
    return frameInterval ? frameInterval : 59.727;
}

- (NSUInteger)channelCount
{
    return 2;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    int serial_size = snes_serialize_size();
    NSMutableData *stateData = [NSMutableData dataWithLength:serial_size];

    if(!snes_serialize((uint8_t *)[stateData mutableBytes], serial_size))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
        block(NO, error);
        return;
    }

    __autoreleasing NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];

    block(success, success ? nil : error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    __autoreleasing NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];

    if(data == nil)
    {
        block(NO, error);
        return;
    }

    int serial_size = snes_serialize_size();
    if(serial_size != [data length])
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the file %@ does not have the right size, %d expected, got: %ld.", fileName, serial_size, [data length]],
        }];
        block(NO, error);
        return;
    }

    if(!snes_unserialize((uint8_t *)[data bytes], serial_size))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"Could not read the file state in %@.", fileName]
        }];
        block(NO, error);
        return;
    }
    
    block(YES, nil);
}

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // VBA expects cheats UPPERCASE
    code = [code uppercaseString];
    
    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    
    NSArray *multipleCodes = [[NSArray alloc] init];
    multipleCodes = [code componentsSeparatedByString:@"+"];
    
    for (NSString *singleCode in multipleCodes)
    {
        if ([singleCode length] == 11 || [singleCode length] == 13 || [singleCode length] == 17) // Code with Address:Value
        {
            // XXXXXXXX:YY || XXXXXXXX:YYYY || XXXXXXXX:YYYYYYYY
            cheatsAddCheatCode([singleCode UTF8String], "code");
        }
        
        if ([singleCode length] == 12) // v1 and v2 GameShark/CodeBreaker code
        {
            // VBA expects 12-character GameShark/CodeBreaker codes in format: XXXXXXXX YYYY
            NSMutableString *formattedCode = [NSMutableString stringWithString:singleCode];
            [formattedCode insertString:@" " atIndex:8];
            
            cheatsAddCBACode([formattedCode UTF8String], "code");
        }
        
        if ([singleCode length] == 16) // GameShark and Action Replay
        {
            if ([type isEqual: @"GameShark"])
                cheatsAddGSACode([singleCode UTF8String], "code", false);
            
            else if ([type isEqual: @"Action Replay"])
                cheatsAddGSACode([singleCode UTF8String], "code", true); // true = v3 AR code
            
            else // default to GBA SP GameShark code (can't determine GS vs AR because same length)
                cheatsAddGSACode([singleCode UTF8String], "code", false);
        }
    }
}

@end

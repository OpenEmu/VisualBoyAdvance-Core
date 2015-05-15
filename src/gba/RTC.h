#ifndef RTC_H
#define RTC_H

enum RTCSTATE
{
    IDLE = 0,
    COMMAND,
    DATA,
    READDATA
};

typedef struct {
    u8 byte0;
    u8 byte1;
    u8 byte2;
    u8 command;
    int dataLen;
    int bits;
    RTCSTATE state;
    u8 data[12];
    // reserved variables for future
    u8 reserved[12];
    bool reserved2;
    u32 reserved3;
} RTCCLOCKDATA;

u16 rtcRead(u32 address);
bool rtcWrite(u32 address, u16 value);
void rtcEnable(bool);
bool rtcIsEnabled();
void rtcReset();

#define RTC_SERIAL_SIZE (sizeof(RTCCLOCKDATA))

void rtcSerialize(uint8_t *& data);
void rtcDeserialize(const uint8_t *& data);

#ifdef __LIBRETRO__
void rtcReadGame(const u8 *&data);
void rtcSaveGame(u8 *&data);
#else
void rtcReadGame(gzFile gzFile);
void rtcSaveGame(gzFile gzFile);
#endif

#endif // RTC_H

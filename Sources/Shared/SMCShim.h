//
//  SMCShim.h
//  BatteryKiller
//
//  AppleSMC 用户客户端（AppleSMC.kext）的二进制接口声明。
//  结构体布局与命令码由内核扩展定义，属于 ABI 约定，任何字段都不能增删或调序。
//  单独放在 C 头里是为了让 Swift 拿到与 C 完全一致的内存布局（Swift 结构体的
//  默认布局不保证与 C 相同），主程序与特权助手都通过 -import-objc-header 引用。
//

#ifndef SMCShim_h
#define SMCShim_h

#include <stdint.h>

/// 发给 AppleSMC.kext 的命令码
enum {
    kSMCUserClientOpen  = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent  = 2,
    kSMCReadKey         = 5,
    kSMCWriteKey        = 6,
    kSMCGetKeyCount     = 7,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo      = 9
};

/// SMC 调用的结果码
enum {
    kSMCSuccess     = 0,
    kSMCError       = 1,
    kSMCKeyNotFound = 0x84
};

/// SMC 固件版本
typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;

/// 电源限制数据。本工具不使用这些字段，保留仅为维持结构体布局
typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

/// SMC 键的元信息
typedef struct {
    uint32_t dataSize;       ///< 数据长度（字节）
    uint32_t dataType;       ///< 四字符类型码，例如 ui8 / hex_
    uint8_t  dataAttributes; ///< 属性位，实测 0xD4 表示可写、0x84 表示只读
} SMCKeyInfoData;

/// 与 AppleSMC.kext 交换的 Mach 消息，总长度固定为 80 字节
typedef struct {
    uint32_t       key;       ///< 四字符键名
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;    ///< 调用结果，0 表示成功
    uint8_t        status;
    uint8_t        data8;     ///< 命令码
    uint32_t       data32;
    uint8_t        bytes[32]; ///< 读写的数据载荷
} SMCParamStruct;

#endif /* SMCShim_h */

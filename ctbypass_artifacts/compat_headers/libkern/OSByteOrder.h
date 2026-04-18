/* Linux compatibility shim for Apple's libkern/OSByteOrder.h */
#ifndef _COMPAT_OSBYTEORDER_H
#define _COMPAT_OSBYTEORDER_H

#include <stdint.h>
#include <byteswap.h>
#include <endian.h>

#define OSSwapInt16(x)   __bswap_16(x)
#define OSSwapInt32(x)   __bswap_32(x)
#define OSSwapInt64(x)   __bswap_64(x)

#if __BYTE_ORDER == __LITTLE_ENDIAN
#define OSSwapHostToLittleInt16(x) ((uint16_t)(x))
#define OSSwapHostToLittleInt32(x) ((uint32_t)(x))
#define OSSwapHostToLittleInt64(x) ((uint64_t)(x))
#define OSSwapLittleToHostInt16(x) ((uint16_t)(x))
#define OSSwapLittleToHostInt32(x) ((uint32_t)(x))
#define OSSwapLittleToHostInt64(x) ((uint64_t)(x))
#define OSSwapHostToBigInt16(x) __bswap_16((uint16_t)(x))
#define OSSwapHostToBigInt32(x) __bswap_32((uint32_t)(x))
#define OSSwapHostToBigInt64(x) __bswap_64((uint64_t)(x))
#define OSSwapBigToHostInt16(x) __bswap_16((uint16_t)(x))
#define OSSwapBigToHostInt32(x) __bswap_32((uint32_t)(x))
#define OSSwapBigToHostInt64(x) __bswap_64((uint64_t)(x))
#else
#define OSSwapHostToLittleInt16(x) __bswap_16((uint16_t)(x))
#define OSSwapHostToLittleInt32(x) __bswap_32((uint32_t)(x))
#define OSSwapHostToLittleInt64(x) __bswap_64((uint64_t)(x))
#define OSSwapLittleToHostInt16(x) __bswap_16((uint16_t)(x))
#define OSSwapLittleToHostInt32(x) __bswap_32((uint32_t)(x))
#define OSSwapLittleToHostInt64(x) __bswap_64((uint64_t)(x))
#define OSSwapHostToBigInt16(x) ((uint16_t)(x))
#define OSSwapHostToBigInt32(x) ((uint32_t)(x))
#define OSSwapHostToBigInt64(x) ((uint64_t)(x))
#define OSSwapBigToHostInt16(x) ((uint16_t)(x))
#define OSSwapBigToHostInt32(x) ((uint32_t)(x))
#define OSSwapBigToHostInt64(x) ((uint64_t)(x))
#endif

#define OSReadLittleInt16(base, off)  OSSwapLittleToHostInt16(*(const uint16_t*)((const char*)(base)+(off)))
#define OSReadLittleInt32(base, off)  OSSwapLittleToHostInt32(*(const uint32_t*)((const char*)(base)+(off)))
#define OSReadLittleInt64(base, off)  OSSwapLittleToHostInt64(*(const uint64_t*)((const char*)(base)+(off)))
#define OSReadBigInt16(base, off)     OSSwapBigToHostInt16(*(const uint16_t*)((const char*)(base)+(off)))
#define OSReadBigInt32(base, off)     OSSwapBigToHostInt32(*(const uint32_t*)((const char*)(base)+(off)))
#define OSReadBigInt64(base, off)     OSSwapBigToHostInt64(*(const uint64_t*)((const char*)(base)+(off)))

#define OSWriteLittleInt16(base, off, val)  (*(uint16_t*)((char*)(base)+(off)) = OSSwapHostToLittleInt16(val))
#define OSWriteLittleInt32(base, off, val)  (*(uint32_t*)((char*)(base)+(off)) = OSSwapHostToLittleInt32(val))
#define OSWriteLittleInt64(base, off, val)  (*(uint64_t*)((char*)(base)+(off)) = OSSwapHostToLittleInt64(val))
#define OSWriteBigInt16(base, off, val)     (*(uint16_t*)((char*)(base)+(off)) = OSSwapHostToBigInt16(val))
#define OSWriteBigInt32(base, off, val)     (*(uint32_t*)((char*)(base)+(off)) = OSSwapHostToBigInt32(val))
#define OSWriteBigInt64(base, off, val)     (*(uint64_t*)((char*)(base)+(off)) = OSSwapHostToBigInt64(val))

#define OSHostByteOrder() (__BYTE_ORDER == __LITTLE_ENDIAN ? 1 : 2)
#define OSLittleEndian 1
#define OSBigEndian 2
#define OSUnknownByteOrder 0

#endif

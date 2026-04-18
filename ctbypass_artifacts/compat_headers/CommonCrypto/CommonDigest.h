/* Linux stub mapping Apple's CommonCrypto digests to OpenSSL */
#ifndef _COMPAT_COMMONCRYPTO_COMMONDIGEST_H
#define _COMPAT_COMMONCRYPTO_COMMONDIGEST_H

#include <openssl/sha.h>

#define CC_SHA1_DIGEST_LENGTH 20
#define CC_SHA224_DIGEST_LENGTH 28
#define CC_SHA256_DIGEST_LENGTH 32
#define CC_SHA384_DIGEST_LENGTH 48
#define CC_SHA512_DIGEST_LENGTH 64

typedef unsigned int CC_LONG;

static inline unsigned char *CC_SHA1(const void *data, CC_LONG len, unsigned char *md) {
    return SHA1((const unsigned char *)data, (size_t)len, md);
}
static inline unsigned char *CC_SHA256(const void *data, CC_LONG len, unsigned char *md) {
    return SHA256((const unsigned char *)data, (size_t)len, md);
}
static inline unsigned char *CC_SHA384(const void *data, CC_LONG len, unsigned char *md) {
    return SHA384((const unsigned char *)data, (size_t)len, md);
}
static inline unsigned char *CC_SHA512(const void *data, CC_LONG len, unsigned char *md) {
    return SHA512((const unsigned char *)data, (size_t)len, md);
}

#endif

//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "Cryptography.h"
#import "NSData+Base64.h"
#import "NSData+OWS.h"
#import "OWSError.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Curve25519Kit/Randomness.h>
#import <openssl/evp.h>

#define HMAC256_KEY_LENGTH 32
#define HMAC256_OUTPUT_LENGTH 32
#define AES_CBC_IV_LENGTH 16
#define AES_KEY_SIZE 32

NS_ASSUME_NONNULL_BEGIN

// Returned by many OpenSSL functions - indicating success
const int kOpenSSLSuccess = 1;

// length of initialization nonce for AES256-GCM
static const NSUInteger kAESGCM256_IVLength = 12;

// length of authentication tag for AES256-GCM
static const NSUInteger kAESGCM256_TagLength = 16;

const NSUInteger kAES256_KeyByteLength = 32;

@implementation OWSAES256Key

+ (nullable instancetype)keyWithData:(NSData *)data
{
    if (data.length != kAES256_KeyByteLength) {
        OWSFail(@"%@ Invalid key length: %lu", self.logTag, (unsigned long)data.length);
        return nil;
    }
    
    return [[self alloc] initWithData:data];
}

+ (instancetype)generateRandomKey
{
    return [self new];
}

- (instancetype)init
{
    return [self initWithData:[Cryptography generateRandomBytes:kAES256_KeyByteLength]];
}

- (instancetype)initWithData:(NSData *)data
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    _keyData = data;
    
    return self;
}

#pragma mark - SecureCoding

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    NSData *keyData = [aDecoder decodeObjectOfClass:[NSData class] forKey:@"keyData"];
    if (keyData.length != kAES256_KeyByteLength) {
        OWSFail(@"Invalid key length: %lu", (unsigned long)keyData.length);
        return nil;
    }
    
    _keyData = keyData;
    
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:_keyData forKey:@"keyData"];
}

@end

#pragma mark -

@implementation AES25GCMEncryptionResult

- (nullable instancetype)initWithCipherText:(NSData *)cipherText
                       initializationVector:(NSData *)initializationVector
                                    authTag:(NSData *)authTag
{
    self = [super init];
    if (!self) {
        return self;
    }

    _ciphertext = [cipherText copy];
    _initializationVector = [initializationVector copy];
    _authTag = [authTag copy];

    if (_ciphertext == nil || _initializationVector.length != kAESGCM256_IVLength
        || _authTag.length != kAESGCM256_TagLength) {
        return nil;
    }

    return self;
}

@end

#pragma mark -

@implementation Cryptography

#pragma mark - random bytes methods

+ (NSData *)generateRandomBytes:(NSUInteger)numberBytes
{
    return [Randomness generateRandomBytes:(int)numberBytes];
}

+ (uint32_t)randomUInt32
{
    size_t size = sizeof(uint32_t);
    NSData *data = [self generateRandomBytes:size];
    uint32_t result = 0;
    [data getBytes:&result range:NSMakeRange(0, size)];
    return result;
}

+ (uint64_t)randomUInt64
{
    size_t size = sizeof(uint64_t);
    NSData *data = [self generateRandomBytes:size];
    uint64_t result = 0;
    [data getBytes:&result range:NSMakeRange(0, size)];
    return result;
}

+ (unsigned)randomUnsigned
{
    size_t size = sizeof(unsigned);
    NSData *data = [self generateRandomBytes:size];
    unsigned result = 0;
    [data getBytes:&result range:NSMakeRange(0, size)];
    return result;
}

#pragma mark - SHA1

// Used by TSContactManager to send hashed/truncated contact list to server.
+ (nullable NSString *)truncatedSHA1Base64EncodedWithoutPadding:(NSString *)string
{
    NSData *_Nullable stringData = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!stringData) {
        OWSFail(@"%@ could not convert string to utf-8.", self.logTag);
        return nil;
    }
    if (stringData.length >= UINT32_MAX) {
        OWSFail(@"%@ string data is too long.", self.logTag);
        return nil;
    }
    uint32_t dataLength = (uint32_t)stringData.length;

    NSMutableData *hashData = [NSMutableData dataWithLength:20];
    CC_SHA1(stringData.bytes, dataLength, hashData.mutableBytes);

    NSData *truncatedData = [hashData subdataWithRange:NSMakeRange(0, 10)];
    return [[truncatedData base64EncodedString] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

#pragma mark - SHA256 Digest

+ (nullable NSData *)computeSHA256Digest:(NSData *)data
{
    return [self computeSHA256Digest:data truncatedToBytes:CC_SHA256_DIGEST_LENGTH];
}

+ (nullable NSData *)computeSHA256Digest:(NSData *)data truncatedToBytes:(NSUInteger)truncatedBytes
{
    if (data.length >= UINT32_MAX) {
        OWSFail(@"%@ data is too long.", self.logTag);
        return nil;
    }
    uint32_t dataLength = (uint32_t)data.length;

    NSMutableData *_Nullable digestData = [[NSMutableData alloc] initWithLength:CC_SHA256_DIGEST_LENGTH];
    if (!digestData) {
        OWSFail(@"%@ could not allocate buffer.", self.logTag);
        return nil;
    }
    CC_SHA256(data.bytes, dataLength, digestData.mutableBytes);
    return [digestData subdataWithRange:NSMakeRange(0, truncatedBytes)];
}

#pragma mark - HMAC/SHA256

+ (nullable NSData *)computeSHA256HMAC:(NSData *)data withHMACKey:(NSData *)HMACKey
{
    if (data.length >= SIZE_MAX) {
        OWSFail(@"%@ data is too long.", self.logTag);
        return nil;
    }
    size_t dataLength = (size_t)data.length;
    if (HMACKey.length >= SIZE_MAX) {
        OWSFail(@"%@ HMAC key is too long.", self.logTag);
        return nil;
    }
    size_t hmacKeyLength = (size_t)HMACKey.length;

    NSMutableData *_Nullable ourHmacData = [[NSMutableData alloc] initWithLength:CC_SHA256_DIGEST_LENGTH];
    if (!ourHmacData) {
        OWSFail(@"%@ could not allocate buffer.", self.logTag);
        return nil;
    }
    CCHmac(kCCHmacAlgSHA256, [HMACKey bytes], hmacKeyLength, [data bytes], dataLength, ourHmacData.mutableBytes);
    return [ourHmacData copy];
}

+ (nullable NSData *)computeSHA1HMAC:(NSData *)data withHMACKey:(NSData *)HMACKey
{
    if (data.length >= SIZE_MAX) {
        OWSFail(@"%@ data is too long.", self.logTag);
        return nil;
    }
    size_t dataLength = (size_t)data.length;
    if (HMACKey.length >= SIZE_MAX) {
        OWSFail(@"%@ HMAC key is too long.", self.logTag);
        return nil;
    }
    size_t hmacKeyLength = (size_t)HMACKey.length;

    NSMutableData *_Nullable ourHmacData = [[NSMutableData alloc] initWithLength:CC_SHA1_DIGEST_LENGTH];
    if (!ourHmacData) {
        OWSFail(@"%@ could not allocate buffer.", self.logTag);
        return nil;
    }
    CCHmac(kCCHmacAlgSHA1, [HMACKey bytes], hmacKeyLength, [data bytes], dataLength, ourHmacData.mutableBytes);
    return [ourHmacData copy];
}

+ (nullable NSData *)truncatedSHA1HMAC:(NSData *)dataToHMAC
                           withHMACKey:(NSData *)HMACKey
                            truncation:(NSUInteger)truncation
{
    OWSAssert(truncation <= CC_SHA1_DIGEST_LENGTH);

    return [[Cryptography computeSHA1HMAC:dataToHMAC withHMACKey:HMACKey] subdataWithRange:NSMakeRange(0, truncation)];
}

+ (nullable NSData *)truncatedSHA256HMAC:(NSData *)dataToHMAC
                             withHMACKey:(NSData *)HMACKey
                              truncation:(NSUInteger)truncation
{
    OWSAssert(truncation <= CC_SHA256_DIGEST_LENGTH);

    return
        [[Cryptography computeSHA256HMAC:dataToHMAC withHMACKey:HMACKey] subdataWithRange:NSMakeRange(0, truncation)];
}

#pragma mark - AES CBC Mode

/**
 * AES256 CBC encrypt then mac. Used to decrypt both signal messages and attachment blobs
 *
 * @return decrypted data or nil if hmac invalid/decryption fails
 */
+ (nullable NSData *)decryptCBCMode:(NSData *)dataToDecrypt
                                key:(NSData *)key
                                 IV:(NSData *)iv
                            version:(nullable NSData *)version
                            HMACKey:(NSData *)hmacKey
                           HMACType:(TSMACType)hmacType
                       matchingHMAC:(NSData *)hmac
                             digest:(nullable NSData *)digest
{
    if (dataToDecrypt.length >= (SIZE_MAX - kCCBlockSizeAES128)) {
        OWSFail(@"%@ data is too long.", self.logTag);
        return nil;
    }

    // Verify hmac of: version? || iv || encrypted data
    NSMutableData *dataToAuth = [NSMutableData data];
    if (version != nil) {
        [dataToAuth appendData:version];
    }

    [dataToAuth appendData:iv];
    [dataToAuth appendData:dataToDecrypt];

    NSData *_Nullable ourHmacData;

    if (hmacType == TSHMACSHA1Truncated10Bytes) {
        ourHmacData = [Cryptography truncatedSHA1HMAC:dataToAuth withHMACKey:hmacKey truncation:10];
    } else if (hmacType == TSHMACSHA256Truncated10Bytes) {
        ourHmacData = [Cryptography truncatedSHA256HMAC:dataToAuth withHMACKey:hmacKey truncation:10];
    } else if (hmacType == TSHMACSHA256AttachementType) {
        ourHmacData =
            [Cryptography truncatedSHA256HMAC:dataToAuth withHMACKey:hmacKey truncation:HMAC256_OUTPUT_LENGTH];
    }

    if (hmac == nil || ![ourHmacData ows_constantTimeIsEqualToData:hmac]) {
        DDLogError(@"%@ Bad HMAC on decrypting payload.", self.logTag);
        // Don't log HMAC in prod
        DDLogDebug(@"%@ %s Bad HMAC on decrypting payload. Their MAC: %@, our MAC: %@",
            self.logTag,
            __PRETTY_FUNCTION__,
            hmac,
            ourHmacData);
        return nil;
    }

    // Optionally verify digest of: version? || iv || encrypted data || hmac
    if (digest) {
        DDLogDebug(@"%@ verifying their digest", self.logTag);
        [dataToAuth appendData:ourHmacData];
        NSData *_Nullable ourDigest = [Cryptography computeSHA256Digest:dataToAuth];
        if (!ourDigest || ![ourDigest ows_constantTimeIsEqualToData:digest]) {
            DDLogWarn(@"%@ Bad digest on decrypting payload", self.logTag);
            // Don't log digest in prod
            DDLogDebug(@"%@ Bad digest on decrypting payload. Their digest: %@, our digest: %@",
                self.logTag,
                digest,
                ourDigest);
            return nil;
        }
    }

    // decrypt
    size_t bufferSize = [dataToDecrypt length] + kCCBlockSizeAES128;
    NSMutableData *_Nullable bufferData = [NSMutableData dataWithLength:bufferSize];
    if (!bufferData) {
        DDLogError(@"%@ Failed to allocate buffer.", self.logTag);
        return nil;
    }

    size_t bytesDecrypted       = 0;
    CCCryptorStatus cryptStatus = CCCrypt(kCCDecrypt,
        kCCAlgorithmAES128,
        kCCOptionPKCS7Padding,
        [key bytes],
        [key length],
        [iv bytes],
        [dataToDecrypt bytes],
        [dataToDecrypt length],
        bufferData.mutableBytes,
        bufferSize,
        &bytesDecrypted);
    if (cryptStatus == kCCSuccess) {
        return [bufferData subdataWithRange:NSMakeRange(0, bytesDecrypted)];
    } else {
        DDLogError(@"%@ Failed CBC decryption", self.logTag);
    }

    return nil;
}

#pragma mark - methods which use AES CBC

+ (nullable NSData *)decryptAppleMessagePayload:(NSData *)payload withSignalingKey:(NSString *)signalingKeyString
{
    OWSAssert(payload);
    OWSAssert(signalingKeyString);

    size_t versionLength = 1;
    size_t ivLength = 16;
    size_t macLength = 10;
    size_t nonCiphertextLength = versionLength + ivLength + macLength;
    size_t ciphertextLength = payload.length - nonCiphertextLength;

    if (payload.length < nonCiphertextLength) {
        OWSFail(@"%@ Invalid payload", self.logTag);
        return nil;
    }
    if (payload.length >= MIN(SIZE_MAX, NSUIntegerMax) - nonCiphertextLength) {
        OWSFail(@"%@ Invalid payload", self.logTag);
        return nil;
    }

    NSUInteger cursor = 0;
    NSData *versionData = [payload subdataWithRange:NSMakeRange(cursor, versionLength)];
    cursor += versionLength;
    NSData *ivData = [payload subdataWithRange:NSMakeRange(cursor, ivLength)];
    cursor += ivLength;
    NSData *ciphertextData = [payload subdataWithRange:NSMakeRange(cursor, ciphertextLength)];
    cursor += ciphertextLength;
    NSData *macData = [payload subdataWithRange:NSMakeRange(cursor, macLength)];

    NSData *signalingKey                = [NSData dataFromBase64String:signalingKeyString];
    NSData *signalingKeyAESKeyMaterial  = [signalingKey subdataWithRange:NSMakeRange(0, 32)];
    NSData *signalingKeyHMACKeyMaterial = [signalingKey subdataWithRange:NSMakeRange(32, 20)];
    return [Cryptography decryptCBCMode:ciphertextData
                                    key:signalingKeyAESKeyMaterial
                                     IV:ivData
                                version:versionData
                                HMACKey:signalingKeyHMACKeyMaterial
                               HMACType:TSHMACSHA256Truncated10Bytes
                           matchingHMAC:macData
                                 digest:nil];
}

+ (nullable NSData *)decryptAttachment:(NSData *)dataToDecrypt
                               withKey:(NSData *)key
                                digest:(nullable NSData *)digest
                          unpaddedSize:(UInt32)unpaddedSize
                                 error:(NSError **)error
{
    if (digest.length <= 0) {
        // This *could* happen with sufficiently outdated clients.
        DDLogError(@"%@ Refusing to decrypt attachment without a digest.", self.logTag);
        *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptMessage,
            NSLocalizedString(@"ERROR_MESSAGE_ATTACHMENT_FROM_OLD_CLIENT",
                @"Error message when unable to receive an attachment because the sending client is too old."));
        return nil;
    }

    if (([dataToDecrypt length] < AES_CBC_IV_LENGTH + HMAC256_OUTPUT_LENGTH) ||
        ([key length] < AES_KEY_SIZE + HMAC256_KEY_LENGTH)) {
        DDLogError(@"%@ Message shorter than crypto overhead!", self.logTag);
        *error = OWSErrorWithCodeDescription(
            OWSErrorCodeFailedToDecryptMessage, NSLocalizedString(@"ERROR_MESSAGE_INVALID_MESSAGE", @""));
        return nil;
    }

    // key: 32 byte AES key || 32 byte Hmac-SHA256 key.
    NSData *encryptionKey = [key subdataWithRange:NSMakeRange(0, AES_KEY_SIZE)];
    NSData *hmacKey       = [key subdataWithRange:NSMakeRange(AES_KEY_SIZE, HMAC256_KEY_LENGTH)];

    // dataToDecrypt: IV || Ciphertext || truncated MAC(IV||Ciphertext)
    NSData *iv                  = [dataToDecrypt subdataWithRange:NSMakeRange(0, AES_CBC_IV_LENGTH)];
    NSData *encryptedAttachment = [dataToDecrypt
        subdataWithRange:NSMakeRange(AES_CBC_IV_LENGTH,
                                     [dataToDecrypt length] - AES_CBC_IV_LENGTH - HMAC256_OUTPUT_LENGTH)];
    NSData *hmac = [dataToDecrypt
        subdataWithRange:NSMakeRange([dataToDecrypt length] - HMAC256_OUTPUT_LENGTH, HMAC256_OUTPUT_LENGTH)];

    NSData *_Nullable paddedPlainText = [Cryptography decryptCBCMode:encryptedAttachment
                                                                 key:encryptionKey
                                                                  IV:iv
                                                             version:nil
                                                             HMACKey:hmacKey
                                                            HMACType:TSHMACSHA256AttachementType
                                                        matchingHMAC:hmac
                                                              digest:digest];
    if (!paddedPlainText) {
        OWSFail(@"%@ couldn't decrypt attachment.", self.logTag);
        *error = OWSErrorWithCodeDescription(
            OWSErrorCodeFailedToDecryptMessage, NSLocalizedString(@"ERROR_MESSAGE_INVALID_MESSAGE", @""));
        return nil;
    } else if (unpaddedSize == 0) {
        // Work around for legacy iOS client's which weren't setting padding size.
        // Since we know those clients pre-date attachment padding we return the entire data.
        DDLogWarn(@"%@ Decrypted attachment with unspecified size.", self.logTag);
        return paddedPlainText;
    } else {
        if (unpaddedSize > paddedPlainText.length) {
            *error = OWSErrorWithCodeDescription(
                OWSErrorCodeFailedToDecryptMessage, NSLocalizedString(@"ERROR_MESSAGE_INVALID_MESSAGE", @""));
            return nil;
        }

        if (unpaddedSize == paddedPlainText.length) {
            DDLogInfo(@"%@ decrypted unpadded attachment.", self.logTag);
            return [paddedPlainText copy];
        } else {
            unsigned long paddingSize = paddedPlainText.length - unpaddedSize;
            DDLogInfo(@"%@ decrypted padded attachment with unpaddedSize: %lu, paddingSize: %lu",
                self.logTag,
                (unsigned long)unpaddedSize,
                paddingSize);
            return [paddedPlainText subdataWithRange:NSMakeRange(0, unpaddedSize)];
        }
    }
}

+ (unsigned long)paddedSize:(unsigned long)unpaddedSize
{
    // Don't enable this until clients are sufficiently rolled out.
    BOOL shouldPad = NO;
    if (shouldPad) {
        // Note: This just rounds up to the nearsest power of two,
        // but the actual padding scheme is TBD
        return pow(2, ceil( log2( unpaddedSize )));
    } else {
        return unpaddedSize;
    }
}

+ (nullable NSData *)encryptAttachmentData:(NSData *)attachmentData
                                    outKey:(NSData *_Nonnull *_Nullable)outKey
                                 outDigest:(NSData *_Nonnull *_Nullable)outDigest
{
    // Due to paddedSize, we need to divide by two.
    if (attachmentData.length >= SIZE_MAX / 2) {
        DDLogError(@"%@ data is too long.", self.logTag);
        return nil;
    }

    NSData *iv            = [Cryptography generateRandomBytes:AES_CBC_IV_LENGTH];
    NSData *encryptionKey = [Cryptography generateRandomBytes:AES_KEY_SIZE];
    NSData *hmacKey       = [Cryptography generateRandomBytes:HMAC256_KEY_LENGTH];

    // The concatenated key for storage
    NSMutableData *attachmentKey = [NSMutableData data];
    [attachmentKey appendData:encryptionKey];
    [attachmentKey appendData:hmacKey];
    *outKey = [attachmentKey copy];

    // Apply any padding
    unsigned long desiredSize = [self paddedSize:attachmentData.length];
    NSMutableData *paddedAttachmentData = [attachmentData mutableCopy];
    paddedAttachmentData.length = desiredSize;

    // Encrypt
    size_t bufferSize = [paddedAttachmentData length] + kCCBlockSizeAES128;
    NSMutableData *_Nullable bufferData = [NSMutableData dataWithLength:bufferSize];
    if (!bufferData) {
        DDLogError(@"%@ Failed to allocate buffer.", self.logTag);
        return nil;
    }

    size_t bytesEncrypted = 0;
    CCCryptorStatus cryptStatus = CCCrypt(kCCEncrypt,
        kCCAlgorithmAES128,
        kCCOptionPKCS7Padding,
        [encryptionKey bytes],
        [encryptionKey length],
        [iv bytes],
        [paddedAttachmentData bytes],
        [paddedAttachmentData length],
        bufferData.mutableBytes,
        bufferSize,
        &bytesEncrypted);

    if (cryptStatus != kCCSuccess) {
        DDLogError(@"%@ %s CCCrypt failed with status: %d", self.logTag, __PRETTY_FUNCTION__, (int32_t)cryptStatus);
        return nil;
    }

    NSData *cipherText = [bufferData subdataWithRange:NSMakeRange(0, bytesEncrypted)];

    NSMutableData *encryptedPaddedData = [NSMutableData data];
    [encryptedPaddedData appendData:iv];
    [encryptedPaddedData appendData:cipherText];

    // compute hmac of: iv || encrypted data
    NSData *_Nullable hmac =
        [Cryptography truncatedSHA256HMAC:encryptedPaddedData withHMACKey:hmacKey truncation:HMAC256_OUTPUT_LENGTH];
    if (!hmac) {
        OWSFail(@"%@ could not compute SHA 256 HMAC.", self.logTag);
        return nil;
    }

    [encryptedPaddedData appendData:hmac];

    // compute digest of: iv || encrypted data || hmac
    NSData *_Nullable digest = [self computeSHA256Digest:encryptedPaddedData];
    if (!digest) {
        OWSFail(@"%@ data is too long.", self.logTag);
        return nil;
    }
    *outDigest = digest;

    return [encryptedPaddedData copy];
}

+ (nullable AES25GCMEncryptionResult *)encryptAESGCMWithData:(NSData *)plaintext
                                 additionalAuthenticatedData:(nullable NSData *)additionalAuthenticatedData
                                                         key:(OWSAES256Key *)key
{
    NSData *initializationVector = [Cryptography generateRandomBytes:kAESGCM256_IVLength];
    NSMutableData *ciphertext = [NSMutableData dataWithLength:plaintext.length];
    NSMutableData *authTag = [NSMutableData dataWithLength:kAESGCM256_TagLength];

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        OWSFail(@"%@ failed to build context while encrypting", self.logTag);
        return nil;
    }

    // Initialise the encryption operation.
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to init encryption", self.logTag);
        return nil;
    }

    // Set IV length if default 12 bytes (96 bits) is not appropriate
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)initializationVector.length, NULL) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to set IV length", self.logTag);
        return nil;
    }

    // Initialise key and IV
    if (EVP_EncryptInit_ex(ctx, NULL, NULL, key.keyData.bytes, initializationVector.bytes) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to set key and iv while encrypting", self.logTag);
        return nil;
    }

    int bytesEncrypted = 0;

    // Provide any AAD data. This can be called zero or more times as
    // required
    if (additionalAuthenticatedData != nil) {
        if (additionalAuthenticatedData.length >= INT_MAX) {
            OWSFail(@"%@ additionalAuthenticatedData too large", self.logTag);
            return nil;
        }
        if (EVP_EncryptUpdate(
                ctx, NULL, &bytesEncrypted, additionalAuthenticatedData.bytes, (int)additionalAuthenticatedData.length)
            != kOpenSSLSuccess) {
            OWSFail(@"%@ encryptUpdate failed", self.logTag);
            return nil;
        }
    }

    if (plaintext.length >= INT_MAX) {
        OWSFail(@"%@ plaintext too large", self.logTag);
        return nil;
    }

    // Provide the message to be encrypted, and obtain the encrypted output.
    //
    // If we wanted to save memory, we could encrypt piece-wise from a plaintext iostream -
    // feeding each chunk to EVP_EncryptUpdate, which can be called multiple times.
    // For simplicity, we currently encrypt the entire plaintext in one shot.
    if (EVP_EncryptUpdate(ctx, ciphertext.mutableBytes, &bytesEncrypted, plaintext.bytes, (int)plaintext.length)
        != kOpenSSLSuccess) {
        OWSFail(@"%@ encryptUpdate failed", self.logTag);
        return nil;
    }
    if (bytesEncrypted != plaintext.length) {
        OWSFail(@"%@ bytesEncrypted != plainTextData.length", self.logTag);
        return nil;
    }

    int finalizedBytes = 0;
    // Finalize the encryption. Normally ciphertext bytes may be written at
    // this stage, but this does not occur in GCM mode
    if (EVP_EncryptFinal_ex(ctx, ciphertext.mutableBytes + bytesEncrypted, &finalizedBytes) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to finalize encryption", self.logTag);
        return nil;
    }
    if (finalizedBytes != 0) {
        OWSFail(@"%@ Unexpected finalized bytes written", self.logTag);
        return nil;
    }

    // Get the tag
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, kAESGCM256_TagLength, authTag.mutableBytes) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to write tag", self.logTag);
        return nil;
    }

    // Clean up
    EVP_CIPHER_CTX_free(ctx);

    AES25GCMEncryptionResult *_Nullable result =
        [[AES25GCMEncryptionResult alloc] initWithCipherText:ciphertext
                                        initializationVector:initializationVector
                                                     authTag:authTag];

    return result;
}

+ (nullable NSData *)decryptAESGCMWithInitializationVector:(NSData *)initializationVector
                                                ciphertext:(NSData *)ciphertext
                               additionalAuthenticatedData:(nullable NSData *)additionalAuthenticatedData
                                                   authTag:(NSData *)authTagFromEncrypt
                                                       key:(OWSAES256Key *)key
{
    OWSAssert(initializationVector.length == kAESGCM256_IVLength);
    OWSAssert(ciphertext.length > 0);
    OWSAssert(authTagFromEncrypt.length == kAESGCM256_TagLength);
    OWSAssert(key);

    NSMutableData *plaintext = [NSMutableData dataWithLength:ciphertext.length];

    // Create and initialise the context
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();

    if (!ctx) {
        OWSFail(@"%@ failed to build context while decrypting", self.logTag);
        return nil;
    }

    // Initialise the decryption operation.
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to init decryption", self.logTag);
        return nil;
    }

    // Set IV length. Not necessary if this is 12 bytes (96 bits)
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, kAESGCM256_IVLength, NULL) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to set key and iv while decrypting", self.logTag);
        return nil;
    }

    // Initialise key and IV
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, key.keyData.bytes, initializationVector.bytes) != kOpenSSLSuccess) {
        OWSFail(@"%@ failed to init decryption", self.logTag);
        return nil;
    }

    int decryptedBytes = 0;

    // Provide any AAD data. This can be called zero or more times as
    // required
    if (additionalAuthenticatedData) {
        if (additionalAuthenticatedData.length >= INT_MAX) {
            OWSFail(@"%@ additionalAuthenticatedData too large", self.logTag);
            return nil;
        }
        if (!EVP_DecryptUpdate(ctx,
                NULL,
                &decryptedBytes,
                additionalAuthenticatedData.bytes,
                (int)additionalAuthenticatedData.length)) {
            OWSFail(@"%@ failed during additionalAuthenticatedData", self.logTag);
            return nil;
        }
    }

    // Provide the message to be decrypted, and obtain the plaintext output.
    //
    // If we wanted to save memory, we could decrypt piece-wise from an iostream -
    // feeding each chunk to EVP_DecryptUpdate, which can be called multiple times.
    // For simplicity, we currently decrypt the entire ciphertext in one shot.
    if (ciphertext.length >= INT_MAX) {
        OWSFail(@"%@ ciphertext too large", self.logTag);
        return nil;
    }
    if (EVP_DecryptUpdate(ctx, plaintext.mutableBytes, &decryptedBytes, ciphertext.bytes, (int)ciphertext.length)
        != kOpenSSLSuccess) {
        OWSFail(@"%@ decryptUpdate failed", self.logTag);
        return nil;
    }

    if (decryptedBytes != ciphertext.length) {
        OWSFail(@"%@ Failed to decrypt entire ciphertext", self.logTag);
        return nil;
    }

    // Set expected tag value. Works in OpenSSL 1.0.1d and later
    if (authTagFromEncrypt.length >= INT_MAX) {
        OWSFail(@"%@ authTagFromEncrypt too large", self.logTag);
        return nil;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)authTagFromEncrypt.length, (void *)authTagFromEncrypt.bytes)
        != kOpenSSLSuccess) {
        OWSFail(@"%@ Failed to set auth tag in decrypt.", self.logTag);
        return nil;
    }

    // Finalise the decryption. A positive return value indicates success,
    // anything else is a failure - the plaintext is not trustworthy.
    int finalBytes = 0;
    int decryptStatus = EVP_DecryptFinal_ex(ctx, (unsigned char *)(plaintext.bytes + decryptedBytes), &finalBytes);

    // AESGCM doesn't write any final bytes
    OWSAssert(finalBytes == 0);

    // Clean up
    EVP_CIPHER_CTX_free(ctx);

    if (decryptStatus > 0) {
        return [plaintext copy];
    } else {
        // This should only happen if the user has changed their profile key, which should only
        // happen currently if they re-register.
        DDLogError(@"%@ Decrypt verification failed", self.logTag);
        return nil;
    }
}

+ (nullable NSData *)encryptAESGCMWithProfileData:(NSData *)plaintext key:(OWSAES256Key *)key
{
    AES25GCMEncryptionResult *result = [self encryptAESGCMWithData:plaintext additionalAuthenticatedData:nil key:key];

    NSMutableData *encryptedData = [result.initializationVector mutableCopy];
    [encryptedData appendData:result.ciphertext];
    [encryptedData appendData:result.authTag];

    return [encryptedData copy];
}

+ (nullable NSData *)decryptAESGCMWithProfileData:(NSData *)encryptedData key:(OWSAES256Key *)key
{
    OWSAssert(encryptedData.length > kAESGCM256_IVLength + kAESGCM256_TagLength);
    NSUInteger cipherTextLength = encryptedData.length - kAESGCM256_IVLength - kAESGCM256_TagLength;

    // encryptedData layout: initializationVector || ciphertext || authTag
    NSData *initializationVector = [encryptedData subdataWithRange:NSMakeRange(0, kAESGCM256_IVLength)];
    NSData *ciphertext = [encryptedData subdataWithRange:NSMakeRange(kAESGCM256_IVLength, cipherTextLength)];
    NSData *authTag =
        [encryptedData subdataWithRange:NSMakeRange(kAESGCM256_IVLength + cipherTextLength, kAESGCM256_TagLength)];

    return [self decryptAESGCMWithInitializationVector:initializationVector
                                            ciphertext:ciphertext
                           additionalAuthenticatedData:nil
                                               authTag:authTag
                                                   key:key];
}

+ (void)seedRandom
{
    unsigned seed = [Cryptography randomUnsigned];
    srand(seed);
}

@end

NS_ASSUME_NONNULL_END

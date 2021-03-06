//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSProvisioningCipher.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Curve25519Kit/Curve25519.h>
#import <HKDFKit/HKDFKit.h>
#import <SignalServiceKit/Cryptography.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSProvisioningCipher ()

@property (nonatomic, readonly) NSData *theirPublicKey;
@property (nonatomic, readonly) ECKeyPair *ourKeyPair;
@property (nonatomic, readonly) NSData *initializationVector;

@end

#pragma mark -

@implementation OWSProvisioningCipher

- (instancetype)initWithTheirPublicKey:(NSData *)theirPublicKey
{
    return [self initWithTheirPublicKey:theirPublicKey
                             ourKeyPair:[Curve25519 generateKeyPair]
                   initializationVector:[Cryptography generateRandomBytes:kCCBlockSizeAES128]];
}

// Private method which exposes dependencies for testing
- (instancetype)initWithTheirPublicKey:(NSData *)theirPublicKey
                            ourKeyPair:(ECKeyPair *)ourKeyPair
                  initializationVector:(NSData *)initializationVector
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    _theirPublicKey = theirPublicKey;
    _ourKeyPair = ourKeyPair;
    _initializationVector = initializationVector;
    
    return self;
}

- (NSData *)ourPublicKey
{
    return self.ourKeyPair.publicKey;
}

- (nullable NSData *)encrypt:(NSData *)dataToEncrypt
{
    NSData *sharedSecret =
        [Curve25519 generateSharedSecretFromPublicKey:self.theirPublicKey andKeyPair:self.ourKeyPair];

    NSData *infoData = [@"TextSecure Provisioning Message" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *nullSalt = [[NSMutableData dataWithLength:32] copy];
    NSData *derivedSecret = [HKDFKit deriveKey:sharedSecret info:infoData salt:nullSalt outputSize:64];
    NSData *cipherKey = [derivedSecret subdataWithRange:NSMakeRange(0, 32)];
    NSData *macKey = [derivedSecret subdataWithRange:NSMakeRange(32, 32)];
    NSAssert(cipherKey.length == 32, @"Cipher Key must be 32 bytes");
    NSAssert(macKey.length == 32, @"Mac Key must be 32 bytes");

    u_int8_t versionByte[] = { 0x01 };
    NSMutableData *message = [NSMutableData dataWithBytes:&versionByte length:1];

    NSData *_Nullable cipherText = [self encrypt:dataToEncrypt withKey:cipherKey];
    if (cipherText == nil) {
        OWSFail(@"%@ Provisioning cipher failed.", self.logTag);
        return nil;
    }
    
    [message appendData:cipherText];

    NSData *_Nullable mac = [self macForMessage:message withKey:macKey];
    if (mac == nil) {
        OWSFail(@"%@ mac failed.", self.logTag);
        return nil;
    }
    [message appendData:mac];

    return [message copy];
}

- (nullable NSData *)encrypt:(NSData *)dataToEncrypt withKey:(NSData *)cipherKey
{
    NSData *iv = self.initializationVector;
    if (iv.length != kCCBlockSizeAES128) {
        OWSFail(@"%@ Unexpected length for iv", self.logTag);
        return nil;
    }
    if (dataToEncrypt.length >= SIZE_MAX - (kCCBlockSizeAES128 + iv.length)) {
        OWSFail(@"%@ data is too long to encrypt.", self.logTag);
        return nil;
    }

    // allow space for message + padding any incomplete block. PKCS7 padding will always add at least one byte.
    size_t ciphertextBufferSize = dataToEncrypt.length + kCCBlockSizeAES128;

    NSMutableData *ciphertextData = [[NSMutableData alloc] initWithLength:ciphertextBufferSize];

    size_t bytesEncrypted = 0;
    CCCryptorStatus cryptStatus = CCCrypt(kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        cipherKey.bytes,
        cipherKey.length,
        iv.bytes,
        dataToEncrypt.bytes,
        dataToEncrypt.length,
        ciphertextData.mutableBytes,
        ciphertextBufferSize,
        &bytesEncrypted);

    if (cryptStatus != kCCSuccess) {
        DDLogError(@"Encryption failed with status: %d", cryptStatus);
        return nil;
    }

    // message format is (iv || ciphertext)
    NSMutableData *encryptedMessage = [NSMutableData new];
    [encryptedMessage appendData:iv];
    [encryptedMessage appendData:[ciphertextData subdataWithRange:NSMakeRange(0, bytesEncrypted)]];
    return [encryptedMessage copy];
}

- (nullable NSData *)macForMessage:(NSData *)message withKey:(NSData *)macKey
{
    return [Cryptography computeSHA256HMAC:message withHMACKey:macKey];
}

@end

NS_ASSUME_NONNULL_END

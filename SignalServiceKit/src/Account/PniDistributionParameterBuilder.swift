//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Curve25519Kit
import SignalCoreKit

public enum PniDistribution {
    enum ParameterGenerationResult {
        case success(Parameters)
        case failure
    }

    /// Parameters for distributing PNI information to linked devices.
    public struct Parameters {
        let pniIdentityKey: Data
        private(set) var devicePniSignedPreKeys: [String: SignedPreKeyRecord] = [:]
        private(set) var pniRegistrationIds: [String: UInt32] = [:]
        private(set) var deviceMessages: [DeviceMessage] = []

        fileprivate init(pniIdentityKey: Data) {
            self.pniIdentityKey = pniIdentityKey
        }

        #if TESTABLE_BUILD

        public static func mock(
            pniIdentityKeyPair: ECKeyPair,
            localDeviceId: UInt32,
            localDevicePniSignedPreKey: SignedPreKeyRecord,
            localDevicePniRegistrationId: UInt32
        ) -> Parameters {
            var mock = Parameters(pniIdentityKey: pniIdentityKeyPair.publicKey)
            mock.addLocalDevice(
                localDeviceId: localDeviceId,
                signedPreKey: localDevicePniSignedPreKey,
                registrationId: localDevicePniRegistrationId
            )
            return mock
        }

        #endif

        fileprivate mutating func addLocalDevice(
            localDeviceId: UInt32,
            signedPreKey: SignedPreKeyRecord,
            registrationId: UInt32
        ) {
            devicePniSignedPreKeys["\(localDeviceId)"] = signedPreKey
            pniRegistrationIds["\(localDeviceId)"] = registrationId
        }

        fileprivate mutating func addLinkedDevice(
            deviceId: UInt32,
            signedPreKey: SignedPreKeyRecord,
            registrationId: UInt32,
            deviceMessage: DeviceMessage
        ) {
            owsAssert(deviceId == deviceMessage.destinationDeviceId)

            devicePniSignedPreKeys["\(deviceId)"] = signedPreKey
            pniRegistrationIds["\(deviceId)"] = registrationId
            deviceMessages.append(deviceMessage)
        }

        func requestParameters() -> [String: Any] {
            [
                "pniIdentityKey": pniIdentityKey.prependKeyType().base64EncodedString(),
                "devicePniSignedPrekeys": devicePniSignedPreKeys.mapValues { OWSRequestFactory.signedPreKeyRequestParameters($0) },
                "deviceMessages": deviceMessages.map { $0.requestParameters() },
                "pniRegistrationIds": pniRegistrationIds
            ]
        }
    }
}

protocol PniDistributionParamaterBuilder {
    /// Generates parameters to distribute a new PNI identity from the primary
    /// to linked devices.
    ///
    /// These parameters include:
    /// - A new public identity key for this account.
    /// - Signed pre-key pairs and registration IDs for all devices. Data for
    ///   the local (primary) device may be fresh or existing.
    /// - An encrypted message for each linked device informing them about the
    ///   new identity. Note that this message contains private key data.
    func buildPniDistributionParameters(
        localAci: ServiceId,
        localAccountId: String,
        localDeviceId: UInt32,
        localUserAllDeviceIds: [UInt32],
        localPniIdentityKeyPair: ECKeyPair,
        localDevicePniSignedPreKey: SignedPreKeyRecord,
        localDevicePniRegistrationId: UInt32
    ) -> Guarantee<PniDistribution.ParameterGenerationResult>
}

final class PniDistributionParameterBuilderImpl: PniDistributionParamaterBuilder {
    private let logger = PrefixedLogger(prefix: "PDPBI")

    private let messageSender: Shims.MessageSender
    private let pniSignedPreKeyStore: Shims.SignedPreKeyStore
    private let schedulers: Schedulers
    private let tsAccountManager: Shims.TSAccountManager

    init(
        messageSender: Shims.MessageSender,
        pniSignedPreKeyStore: Shims.SignedPreKeyStore,
        schedulers: Schedulers,
        tsAccountManager: Shims.TSAccountManager
    ) {
        self.messageSender = messageSender
        self.pniSignedPreKeyStore = pniSignedPreKeyStore
        self.schedulers = schedulers
        self.tsAccountManager = tsAccountManager
    }

    func buildPniDistributionParameters(
        localAci: ServiceId,
        localAccountId: String,
        localDeviceId: UInt32,
        localUserAllDeviceIds: [UInt32],
        localPniIdentityKeyPair: ECKeyPair,
        localDevicePniSignedPreKey: SignedPreKeyRecord,
        localDevicePniRegistrationId: UInt32
    ) -> Guarantee<PniDistribution.ParameterGenerationResult> {
        var parameters = PniDistribution.Parameters(pniIdentityKey: localPniIdentityKeyPair.publicKey)

        // Include the signed pre key & registration ID for the current device.
        parameters.addLocalDevice(
            localDeviceId: localDeviceId,
            signedPreKey: localDevicePniSignedPreKey,
            registrationId: localDevicePniRegistrationId
        )

        // Create a signed pre key & registration ID for linked devices.
        let linkedDevicePromises: [Promise<LinkedDevicePniGenerationParams?>]
        do {
            linkedDevicePromises = try buildLinkedDevicePniGenerationParams(
                localAci: localAci,
                localAccountId: localAccountId,
                localDeviceId: localDeviceId,
                localUserAllDeviceIds: localUserAllDeviceIds,
                pniIdentityKeyPair: localPniIdentityKeyPair
            )
        } catch {
            return .value(.failure)
        }

        return firstly(on: schedulers.sync) { [schedulers] () -> Guarantee<[Result<LinkedDevicePniGenerationParams?, Error>]> in
            Guarantee.when(
                on: schedulers.global(),
                resolved: linkedDevicePromises
            )
        }.map(on: schedulers.sync) { linkedDeviceParamResults -> PniDistribution.ParameterGenerationResult in
            for linkedDeviceParamResult in linkedDeviceParamResults {
                switch linkedDeviceParamResult {
                case .success(let param):
                    guard let param else { continue }

                    parameters.addLinkedDevice(
                        deviceId: param.deviceId,
                        signedPreKey: param.signedPreKey,
                        registrationId: param.registrationId,
                        deviceMessage: param.deviceMessage
                    )
                case .failure:
                    // If we have any errors, return immediately.
                    return .failure
                }
            }

            return .success(parameters)
        }
    }

    /// Bundles parameters concerning linked devices and PNI identity
    /// generation.
    private struct LinkedDevicePniGenerationParams {
        let deviceId: UInt32
        let signedPreKey: SignedPreKeyRecord
        let registrationId: UInt32
        let deviceMessage: DeviceMessage
    }

    /// Asynchronously build params for generating a new PNI identity, for each
    /// linked device.
    /// - Returns
    /// One promise per linked device for which PNI identity generation params
    /// are being built. A `nil` param in a resolved promise indicates a linked
    /// device that is no longer valid, and was ignored.
    private func buildLinkedDevicePniGenerationParams(
        localAci: ServiceId,
        localAccountId: String,
        localDeviceId: UInt32,
        localUserAllDeviceIds: [UInt32],
        pniIdentityKeyPair: ECKeyPair
    ) throws -> [Promise<LinkedDevicePniGenerationParams?>] {
        let localUserLinkedDeviceIds: [UInt32] = localUserAllDeviceIds.filter { deviceId in
            deviceId != localDeviceId
        }

        guard localUserLinkedDeviceIds.count == (localUserAllDeviceIds.count - 1) else {
            let message = "Local device ID missing - can't build linked device params if the local device isn't registered."
            logger.error(message)
            throw OWSGenericError(message)
        }

        return localUserLinkedDeviceIds.map { linkedDeviceId -> Promise<LinkedDevicePniGenerationParams?> in
            let logger = logger

            let signedPreKey = pniSignedPreKeyStore.generateSignedPreKey(signedBy: pniIdentityKeyPair)
            let registrationId = tsAccountManager.generateRegistrationId()

            logger.info("Building device message for device with ID \(linkedDeviceId).")

            return encryptPniDistributionMessage(
                recipientId: localAccountId,
                recipientAci: localAci,
                recipientDeviceId: linkedDeviceId,
                identityKeyPair: pniIdentityKeyPair,
                signedPreKey: signedPreKey,
                registrationId: registrationId
            ).map(on: schedulers.sync) { deviceMessage -> LinkedDevicePniGenerationParams? in
                guard let deviceMessage else {
                    logger.warn("Missing device message - is device with ID \(linkedDeviceId) invalid?")
                    return nil
                }

                logger.info("Built device message for device with ID \(linkedDeviceId).")

                return LinkedDevicePniGenerationParams(
                    deviceId: linkedDeviceId,
                    signedPreKey: signedPreKey,
                    registrationId: registrationId,
                    deviceMessage: deviceMessage
                )
            }.recover(on: schedulers.sync) { error throws -> Promise<LinkedDevicePniGenerationParams?> in
                logger.error("Failed to build device message for device with ID \(linkedDeviceId): \(error).")
                throw error
            }
        }
    }

    /// Builds a ``DeviceMessage`` for the given parameters, for delivery to a
    /// linked device.
    ///
    /// - Returns
    /// The message for the linked device. If `nil`, indicates the device was
    /// invalid and should be skipped.
    private func encryptPniDistributionMessage(
        recipientId: String,
        recipientAci: ServiceId,
        recipientDeviceId: UInt32,
        identityKeyPair: ECKeyPair,
        signedPreKey: SignedPreKeyRecord,
        registrationId: UInt32
    ) -> Promise<DeviceMessage?> {
        let message = PniDistributionSyncMessage(
            pniIdentityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            registrationId: registrationId
        )

        let plaintextContent: Data
        do {
            plaintextContent = try message.buildSerializedMessageProto()
        } catch let error {
            return .init(error: error)
        }

        return firstly(on: schedulers.global()) { () throws -> DeviceMessage? in
            // Important to wrap this in asynchronity, since it might make
            // blocking network requests.
            let deviceMessage: DeviceMessage? = try self.messageSender.buildDeviceMessage(
                forMessagePlaintextContent: plaintextContent,
                messageEncryptionStyle: .whisper,
                recipientId: recipientId,
                serviceId: recipientAci,
                deviceId: recipientDeviceId,
                isOnlineMessage: false,
                isTransientSenderKeyDistributionMessage: false,
                isStoryMessage: false,
                isResendRequestMessage: false,
                udSendingParamsProvider: nil // Sync messages do not use UD
            )

            return deviceMessage
        }
    }
}

// MARK: - Shims

extension PniDistributionParameterBuilderImpl {
    enum Shims {
        typealias MessageSender = _PniDistributionParameterBuilder_MessageSender_Shim
        typealias SignedPreKeyStore = _PniDistributionParameterBuilder_SignedPreKeyStore_Shim
        typealias TSAccountManager = _PniDistributionParameterBuilder_TSAccountManager_Shim
    }

    enum Wrappers {
        typealias MessageSender = _PniDistributionParameterBuilder_MessageSender_Wrapper
        typealias SignedPreKeyStore = _PniDistributionParameterBuilder_SignedPreKeyStore_Wrapper
        typealias TSAccountManager = _PniDistributionParameterBuilder_TSAccountManager_Wrapper
    }
}

// MARK: MessageSender

protocol _PniDistributionParameterBuilder_MessageSender_Shim {
    func buildDeviceMessage(
        forMessagePlaintextContent messagePlaintextContent: Data,
        messageEncryptionStyle: EncryptionStyle,
        recipientId: String,
        serviceId: ServiceId,
        deviceId: UInt32,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        isStoryMessage: Bool,
        isResendRequestMessage: Bool,
        udSendingParamsProvider: UDSendingParamsProvider?
    ) throws -> DeviceMessage?
}

class _PniDistributionParameterBuilder_MessageSender_Wrapper: _PniDistributionParameterBuilder_MessageSender_Shim {
    private let messageSender: MessageSender

    init(_ messageSender: MessageSender) {
        self.messageSender = messageSender
    }

    func buildDeviceMessage(
        forMessagePlaintextContent messagePlaintextContent: Data,
        messageEncryptionStyle: EncryptionStyle,
        recipientId: String,
        serviceId: ServiceId,
        deviceId: UInt32,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        isStoryMessage: Bool,
        isResendRequestMessage: Bool,
        udSendingParamsProvider: UDSendingParamsProvider?
    ) throws -> DeviceMessage? {
        try messageSender.buildDeviceMessage(
            messagePlaintextContent: messagePlaintextContent,
            messageEncryptionStyle: messageEncryptionStyle,
            recipientId: recipientId,
            serviceId: serviceId,
            deviceId: deviceId,
            isOnlineMessage: isOnlineMessage,
            isTransientSenderKeyDistributionMessage: isTransientSenderKeyDistributionMessage,
            isStoryMessage: isStoryMessage,
            isResendRequestMessage: isResendRequestMessage,
            udSendingParamsProvider: udSendingParamsProvider
        )
    }
}

// MARK: SignedPreKeyStore

protocol _PniDistributionParameterBuilder_SignedPreKeyStore_Shim {
    func generateSignedPreKey(signedBy: ECKeyPair) -> SignedPreKeyRecord
}

class _PniDistributionParameterBuilder_SignedPreKeyStore_Wrapper: _PniDistributionParameterBuilder_SignedPreKeyStore_Shim {
    private let signedPreKeyStore: SSKSignedPreKeyStore

    init(_ signedPreKeyStore: SSKSignedPreKeyStore) {
        self.signedPreKeyStore = signedPreKeyStore
    }

    func generateSignedPreKey(signedBy: ECKeyPair) -> SignedPreKeyRecord {
        return SSKSignedPreKeyStore.generateSignedPreKey(signedBy: signedBy)
    }
}

// MARK: TSAccountManager

protocol _PniDistributionParameterBuilder_TSAccountManager_Shim {
    func generateRegistrationId() -> UInt32
}

class _PniDistributionParameterBuilder_TSAccountManager_Wrapper: _PniDistributionParameterBuilder_TSAccountManager_Shim {
    private let tsAccountManager: TSAccountManager

    init(_ tsAccountManager: TSAccountManager) {
        self.tsAccountManager = tsAccountManager
    }

    func generateRegistrationId() -> UInt32 {
        return TSAccountManager.generateRegistrationId()
    }
}

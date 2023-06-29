//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit

public protocol RecipientMerger {
    /// We're registering, linking, changing our number, etc. This is the only
    /// time we're allowed to "merge" the identifiers for our own account.
    func applyMergeForLocalAccount(
        aci: ServiceId,
        pni: ServiceId?,
        phoneNumber: E164,
        tx: DBWriteTransaction
    ) -> SignalRecipient

    /// We've learned about an association from another device. These sources
    /// don't indicate whether a ServiceId is an ACI or PNI.
    func applyMergeFromLinkedDevice(
        localIdentifiers: LocalIdentifiers,
        serviceId: ServiceId,
        phoneNumber: E164?,
        tx: DBWriteTransaction
    ) -> SignalRecipient

    /// We've learned about an association from CDS.
    func applyMergeFromContactDiscovery(
        localIdentifiers: LocalIdentifiers,
        aci: ServiceId,
        phoneNumber: E164,
        tx: DBWriteTransaction
    ) -> SignalRecipient

    /// We've learned about an association from a Sealed Sender message. These
    /// always come from an ACI, but they might not have a phone number if phone
    /// number sharing is disabled.
    func applyMergeFromSealedSender(
        localIdentifiers: LocalIdentifiers,
        aci: ServiceId,
        phoneNumber: E164?,
        tx: DBWriteTransaction
    ) -> SignalRecipient
}

protocol RecipientMergeObserver {
    /// We are about to learn a new association between identifiers.
    ///
    /// This is called for the identifiers that will no longer be linked.
    func willBreakAssociation(serviceId: ServiceId, phoneNumber: E164, transaction: DBWriteTransaction)

    /// We just learned a new association between identifiers.
    ///
    /// If you provide only a single identifier to a merge, then it's not
    /// possible for us to learn about an association. However, if you provide
    /// two or more identifiers, and if it's the first time we've learned that
    /// they're linked, this callback will be invoked.
    func didLearnAssociation(mergedRecipient: MergedRecipient, transaction: DBWriteTransaction)
}

struct MergedRecipient {
    let serviceId: ServiceId
    let oldPhoneNumber: String?
    let newPhoneNumber: E164
    let isLocalRecipient: Bool
    let signalRecipient: SignalRecipient
}

protocol RecipientMergerTemporaryShims {
    func clearMappings(phoneNumber: E164, transaction: DBWriteTransaction)
    func clearMappings(serviceId: ServiceId, transaction: DBWriteTransaction)
    func didUpdatePhoneNumber(
        oldServiceIdString: String?,
        oldPhoneNumber: String?,
        newServiceIdString: String?,
        newPhoneNumber: E164?,
        transaction: DBWriteTransaction
    )
    func hasActiveSignalProtocolSession(recipientId: String, deviceId: Int32, transaction: DBWriteTransaction) -> Bool
}

class RecipientMergerImpl: RecipientMerger {
    private let temporaryShims: RecipientMergerTemporaryShims
    private let observers: [RecipientMergeObserver]
    private let recipientFetcher: RecipientFetcher
    private let dataStore: RecipientDataStore
    private let storageServiceManager: StorageServiceManager

    /// Initializes a RecipientMerger.
    ///
    /// - Parameter observers: Observers that are notified after a new
    /// association is learned. They are notified in the same transaction in
    /// which we learned about the new association, and they are notified in the
    /// order in which they are provided.
    init(
        temporaryShims: RecipientMergerTemporaryShims,
        observers: [RecipientMergeObserver],
        recipientFetcher: RecipientFetcher,
        dataStore: RecipientDataStore,
        storageServiceManager: StorageServiceManager
    ) {
        self.temporaryShims = temporaryShims
        self.observers = observers
        self.recipientFetcher = recipientFetcher
        self.dataStore = dataStore
        self.storageServiceManager = storageServiceManager
    }

    static func buildObservers(
        groupMemberUpdater: GroupMemberUpdater,
        groupMemberStore: GroupMemberStore,
        interactionStore: InteractionStore,
        signalServiceAddressCache: SignalServiceAddressCache,
        threadAssociatedDataStore: ThreadAssociatedDataStore,
        threadStore: ThreadStore,
        userProfileStore: UserProfileStore
    ) -> [RecipientMergeObserver] {
        [
            signalServiceAddressCache,
            SignalAccountMergeObserver(),
            UserProfileMerger(userProfileStore: userProfileStore),
            // The group member MergeObserver depends on `SignalServiceAddressCache`,
            // so ensure that one's listed first.
            GroupMemberMergeObserverImpl(
                threadStore: threadStore,
                groupMemberUpdater: groupMemberUpdater,
                groupMemberStore: groupMemberStore
            ),
            PhoneNumberChangedMessageInserter(
                groupMemberStore: groupMemberStore,
                interactionStore: interactionStore,
                threadAssociatedDataStore: threadAssociatedDataStore,
                threadStore: threadStore
            )
        ]
    }

    func applyMergeForLocalAccount(
        aci: ServiceId,
        pni: ServiceId?,
        phoneNumber: E164,
        tx: DBWriteTransaction
    ) -> SignalRecipient {
        return mergeAlways(serviceId: aci, phoneNumber: phoneNumber, isLocalRecipient: true, tx: tx)
    }

    func applyMergeFromLinkedDevice(
        localIdentifiers: LocalIdentifiers,
        serviceId: ServiceId,
        phoneNumber: E164?,
        tx: DBWriteTransaction
    ) -> SignalRecipient {
        guard let phoneNumber else {
            return recipientFetcher.fetchOrCreate(serviceId: serviceId, tx: tx)
        }
        return mergeIfNotLocalIdentifier(localIdentifiers: localIdentifiers, serviceId: serviceId, phoneNumber: phoneNumber, tx: tx)
    }

    func applyMergeFromSealedSender(
        localIdentifiers: LocalIdentifiers,
        aci: ServiceId,
        phoneNumber: E164?,
        tx: DBWriteTransaction
    ) -> SignalRecipient {
        guard let phoneNumber else {
            return recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
        }
        return mergeIfNotLocalIdentifier(localIdentifiers: localIdentifiers, serviceId: aci, phoneNumber: phoneNumber, tx: tx)
    }

    func applyMergeFromContactDiscovery(
        localIdentifiers: LocalIdentifiers,
        aci: ServiceId,
        phoneNumber: E164,
        tx: DBWriteTransaction
    ) -> SignalRecipient {
        return mergeIfNotLocalIdentifier(localIdentifiers: localIdentifiers, serviceId: aci, phoneNumber: phoneNumber, tx: tx)
    }

    /// Performs a merge unless a provided identifier refers to the local user.
    ///
    /// With the exception of registration, change number, etc., we're never
    /// allowed to initiate a merge with our own identifiers. Instead, we simply
    /// return whichever recipient exists for the provided `serviceId`.
    private func mergeIfNotLocalIdentifier(
        localIdentifiers: LocalIdentifiers,
        serviceId: ServiceId,
        phoneNumber: E164,
        tx: DBWriteTransaction
    ) -> SignalRecipient {
        if localIdentifiers.contains(serviceId: serviceId) || localIdentifiers.contains(phoneNumber: phoneNumber) {
            return recipientFetcher.fetchOrCreate(serviceId: serviceId, tx: tx)
        }
        return mergeAlways(serviceId: serviceId, phoneNumber: phoneNumber, isLocalRecipient: false, tx: tx)
    }

    /// Performs a merge for the provided identifiers.
    ///
    /// There may be a ``SignalRecipient`` for one or more of the provided
    /// identifiers. If there is, we'll update and return that value (see the
    /// rules below). Otherwise, we'll create a new instance.
    ///
    /// A merge indicates that `serviceId` & `phoneNumber` refer to the same
    /// account. As part of this operation, the database will be updated to
    /// reflect that relationship.
    ///
    /// In general, the rules we follow when applying changes are:
    ///
    /// * ACIs are immutable and representative of an account. We never change
    /// the ACI of a ``SignalRecipient`` from one ACI to another; instead we
    /// create a new ``SignalRecipient``. (However, the ACI *may* change from a
    /// nil value to a nonnil value.)
    ///
    /// * Phone numbers are transient and can move freely between ACIs. When
    /// they do, we must backfill the database to reflect the change.
    private func mergeAlways(
        serviceId: ServiceId,
        phoneNumber: E164,
        isLocalRecipient: Bool,
        tx transaction: DBWriteTransaction
    ) -> SignalRecipient {
        let serviceIdRecipient = dataStore.fetchRecipient(serviceId: serviceId, transaction: transaction)

        // If these values have already been merged, we can return the result
        // without any modifications. This will be the path taken in 99% of cases
        // (ie, we'll hit this path every time a recipient sends you a message,
        // assuming they haven't changed their phone number).
        if let serviceIdRecipient, serviceIdRecipient.phoneNumber == phoneNumber.stringValue {
            return serviceIdRecipient
        }

        // In every other case, we need to change *something*. The goal of the
        // remainder of this method is to ensure there's a `SignalRecipient` such
        // that calling this method again, immediately, with the same parameters
        // would match the the prior `if` check and return early without making any
        // modifications.

        let oldPhoneNumber = serviceIdRecipient?.phoneNumber

        let phoneNumberRecipient = dataStore.fetchRecipient(phoneNumber: phoneNumber.stringValue, transaction: transaction)

        // If PN_1 is associated with ACI_A when this method starts, and if we're
        // trying to associate PN_1 with ACI_B, then we should ensure everything
        // that currently references PN_1 is updated to reference ACI_A. At this
        // point in time, everything we've saved locally with PN_1 is associated
        // with the ACI_A account, so we should mark it as such in the database.
        // After this point, everything new will be associated with ACI_B.
        if let phoneNumberRecipient, let oldServiceId = phoneNumberRecipient.serviceId {
            for observer in observers {
                observer.willBreakAssociation(serviceId: oldServiceId, phoneNumber: phoneNumber, transaction: transaction)
            }
        }

        let mergedRecipient: SignalRecipient
        switch _mergeHighTrust(
            serviceId: serviceId,
            phoneNumber: phoneNumber,
            serviceIdRecipient: serviceIdRecipient,
            phoneNumberRecipient: phoneNumberRecipient,
            transaction: transaction
        ) {
        case .some(let updatedRecipient):
            mergedRecipient = updatedRecipient
            dataStore.updateRecipient(mergedRecipient, transaction: transaction)
            storageServiceManager.recordPendingUpdates(updatedAccountIds: [mergedRecipient.accountId])
        case .none:
            mergedRecipient = SignalRecipient(serviceId: serviceId, phoneNumber: phoneNumber)
            dataStore.insertRecipient(mergedRecipient, transaction: transaction)
        }

        for observer in observers {
            observer.didLearnAssociation(
                mergedRecipient: MergedRecipient(
                    serviceId: serviceId,
                    oldPhoneNumber: oldPhoneNumber,
                    newPhoneNumber: phoneNumber,
                    isLocalRecipient: isLocalRecipient,
                    signalRecipient: mergedRecipient
                ),
                transaction: transaction
            )
        }

        return mergedRecipient
    }

    private func _mergeHighTrust(
        serviceId: ServiceId,
        phoneNumber: E164,
        serviceIdRecipient: SignalRecipient?,
        phoneNumberRecipient: SignalRecipient?,
        transaction: DBWriteTransaction
    ) -> SignalRecipient? {
        if let serviceIdRecipient {
            if let phoneNumberRecipient {
                if phoneNumberRecipient.serviceIdString == nil && serviceIdRecipient.phoneNumber == nil {
                    // These are the same, but not fully complete; we need to merge them.
                    return mergeRecipients(
                        serviceId: serviceId,
                        serviceIdRecipient: serviceIdRecipient,
                        phoneNumber: phoneNumber,
                        phoneNumberRecipient: phoneNumberRecipient,
                        transaction: transaction
                    )
                }

                // Ordering is critical here. We must remove the phone number from the old
                // recipient *before* we assign the phone number to the new recipient in
                // case there are any legacy phone number-only records in the database.

                updateRecipient(phoneNumberRecipient, phoneNumber: nil, transaction: transaction)
                dataStore.updateRecipient(phoneNumberRecipient, transaction: transaction)

                // Fall through now that we've cleaned up `phoneNumberRecipient`.
            }

            // We've already used `updateRecipient(_:phoneNumber:…)` (if necessary) to
            // ensure that `phoneNumberInstance` doesn't use `phoneNumber`.
            //
            // However, that will only update mappings in other database tables that
            // exactly match the address components of `phoneNumberInstance`. (?)
            //
            // The mappings in other tables might not exactly match the mappings in the
            // `SignalRecipient` table. Therefore, to avoid crashes and other mapping
            // problems, we need to ensure that no other tables have mappings that use
            // `phoneNumber` _before_ we update `serviceIdRecipient`'s phone number.
            temporaryShims.clearMappings(phoneNumber: phoneNumber, transaction: transaction)

            if let oldPhoneNumber = serviceIdRecipient.phoneNumber {
                Logger.info("Learned serviceId \(serviceId) changed from old phoneNumber \(oldPhoneNumber) to new phoneNumber \(phoneNumber)")
            } else {
                Logger.info("Learned serviceId \(serviceId) is associated with phoneNumber \(phoneNumber)")
            }

            updateRecipient(serviceIdRecipient, phoneNumber: phoneNumber, transaction: transaction)
            return serviceIdRecipient
        }

        if let phoneNumberRecipient {
            // There is no SignalRecipient for the new ServiceId, but other db tables
            // might have mappings for the new ServiceId. We need to clear that out.
            temporaryShims.clearMappings(serviceId: serviceId, transaction: transaction)

            if phoneNumberRecipient.serviceIdString != nil {
                // We can't change the ServiceId because it's non-empty. Instead, we must
                // create a new SignalRecipient. We clear the phone number here since it
                // will belong to the new SignalRecipient.
                Logger.info("Learned phoneNumber \(phoneNumber) transferred to serviceId \(serviceId)")
                updateRecipient(phoneNumberRecipient, phoneNumber: nil, transaction: transaction)
                dataStore.updateRecipient(phoneNumberRecipient, transaction: transaction)
                return nil
            }

            Logger.info("Learned serviceId \(serviceId) is associated with phoneNumber \(phoneNumber)")
            phoneNumberRecipient.serviceId = serviceId
            return phoneNumberRecipient
        }

        // We couldn't find a recipient, so create a new one.
        return nil
    }

    private func updateRecipient(
        _ recipient: SignalRecipient,
        phoneNumber: E164?,
        transaction: DBWriteTransaction
    ) {
        let oldPhoneNumber = recipient.phoneNumber?.nilIfEmpty
        let oldServiceIdString = recipient.serviceIdString

        recipient.phoneNumber = phoneNumber?.stringValue

        if recipient.phoneNumber == nil && oldServiceIdString == nil {
            Logger.warn("Clearing out the phone number on a recipient with no serviceId; old phone number: \(String(describing: oldPhoneNumber))")
            // Fill in a random UUID, so we can complete the change and maintain a common
            // association for all the records and not leave them dangling. This should
            // in general never happen.
            recipient.serviceId = ServiceId(UUID())
        } else {
            Logger.info("Changing the phone number on a recipient; serviceId: \(oldServiceIdString ?? "nil"), phoneNumber: \(oldPhoneNumber ?? "nil") -> \(recipient.phoneNumber ?? "nil")")
        }

        temporaryShims.didUpdatePhoneNumber(
            oldServiceIdString: oldServiceIdString,
            oldPhoneNumber: oldPhoneNumber,
            newServiceIdString: recipient.serviceIdString,
            newPhoneNumber: phoneNumber,
            transaction: transaction
        )
    }

    private func mergeRecipients(
        serviceId: ServiceId,
        serviceIdRecipient: SignalRecipient,
        phoneNumber: E164,
        phoneNumberRecipient: SignalRecipient,
        transaction: DBWriteTransaction
    ) -> SignalRecipient {
        owsAssertDebug(
            serviceIdRecipient.phoneNumber == nil
            || serviceIdRecipient.phoneNumber == phoneNumber.stringValue
        )
        owsAssertDebug(
            phoneNumberRecipient.serviceIdString == nil
            || phoneNumberRecipient.serviceIdString == serviceId.uuidValue.uuidString
        )

        // We have separate recipients in the db for the uuid and phone number.
        // There isn't an ideal way to do this, but we need to converge on one
        // recipient and discard the other.

        // We try to preserve the recipient that has a session.
        // (Note that we don't check for PNI sessions; we always prefer the ACI session there.)
        let hasSessionForServiceId = temporaryShims.hasActiveSignalProtocolSession(
            recipientId: serviceIdRecipient.accountId,
            deviceId: Int32(OWSDevice.primaryDeviceId),
            transaction: transaction
        )
        let hasSessionForPhoneNumber = temporaryShims.hasActiveSignalProtocolSession(
            recipientId: phoneNumberRecipient.accountId,
            deviceId: Int32(OWSDevice.primaryDeviceId),
            transaction: transaction
        )

        let winningRecipient: SignalRecipient
        let losingRecipient: SignalRecipient

        // We want to retain the phone number recipient only if it has a session
        // and the ServiceId recipient doesn't. Historically, we tried to be clever and
        // pick the session that had seen more use, but merging sessions should
        // only happen in exceptional circumstances these days.
        if !hasSessionForServiceId && hasSessionForPhoneNumber {
            Logger.warn("Discarding serviceId recipient in favor of phone number recipient.")
            winningRecipient = phoneNumberRecipient
            losingRecipient = serviceIdRecipient
        } else {
            Logger.warn("Discarding phone number recipient in favor of serviceId recipient.")
            winningRecipient = serviceIdRecipient
            losingRecipient = phoneNumberRecipient
        }
        owsAssertBeta(winningRecipient !== losingRecipient)

        // Make sure the winning recipient is fully qualified.
        winningRecipient.phoneNumber = phoneNumber.stringValue
        winningRecipient.serviceId = serviceId

        // Discard the losing recipient.
        // TODO: Should we clean up any state related to the discarded recipient?
        dataStore.removeRecipient(losingRecipient, transaction: transaction)

        return winningRecipient
    }
}

// MARK: - SignalServiceAddressCache

extension SignalServiceAddressCache: RecipientMergeObserver {
    func willBreakAssociation(serviceId: ServiceId, phoneNumber: E164, transaction: DBWriteTransaction) {}

    func didLearnAssociation(mergedRecipient: MergedRecipient, transaction: DBWriteTransaction) {
        updateRecipient(mergedRecipient.signalRecipient)

        // If there are any threads with addresses that have been merged, we should
        // reload them from disk. This allows us to rebuild the addresses with the
        // proper hash values.
        modelReadCaches.evacuateAllCaches()
    }
}

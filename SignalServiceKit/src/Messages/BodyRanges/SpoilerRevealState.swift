//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Used to uniquely identify one iteration of an interaction even if edits are applied.
/// Note that the interaction's uniqueId, rowId, and sortId always point to the latest edit,
/// so when an edit is applied they point to the new version not the old version.
/// This is used instead to continue to point to the old version.
///
/// authorUuid is allowed to be null for outgoing or system messages because timestamp can
/// be considered unique on its own for messages generated by oneself.
/// Incoming messages should always have non-null authorUuid.
/// NOTE: be careful using this for messages from before the introduction of uuids.
/// Currently used for text formatting spoilers which were introduced after uuids.
public struct InteractionSnapshotIdentifier: Equatable, Hashable {
    let timestamp: UInt64
    // Note: this will always be the aci for incoming messages
    // and nil for local/outgoing messages.
    let authorUuid: String?

    public init(timestamp: UInt64, authorUuid: String?) {
        self.timestamp = timestamp
        self.authorUuid = authorUuid
    }

    public static func fromInteraction(_ interaction: TSInteraction) -> Self {
        return .init(timestamp: interaction.timestamp, authorUuid: (interaction as? TSIncomingMessage)?.authorUUID)
    }
}

// MARK: -

public protocol SpoilerRevealStateObserver: NSObjectProtocol {
    func didUpdateRevealedSpoilers(_ spoilerReveal: SpoilerRevealState)
}

@objc
public class SpoilerRevealState: NSObject {
    private var revealedSpoilerIdsByMessage = [InteractionSnapshotIdentifier: Set<StyleIdType>]()

    /// Returns the set of IDs in the ordered list of spoiler ranges for a given message that
    /// should be revealed.
    public func revealedSpoilerIds(
        interactionIdentifier: InteractionSnapshotIdentifier
    ) -> Set<StyleIdType> {
        return revealedSpoilerIdsByMessage[interactionIdentifier] ?? []
    }

    public func setSpoilerRevealed(
        withID id: StyleIdType,
        interactionIdentifier: InteractionSnapshotIdentifier
    ) {
        var revealedIds = revealedSpoilerIdsByMessage[interactionIdentifier] ?? Set()
        revealedIds.insert(id)
        revealedSpoilerIdsByMessage[interactionIdentifier] = revealedIds
        observers[interactionIdentifier]?.forEach {
            $0.value?.didUpdateRevealedSpoilers(self)
        }
    }

    private var observers = [InteractionSnapshotIdentifier: [Weak<SpoilerRevealStateObserver>]]()

    public func observeChanges(
        for interactionIdentifier: InteractionSnapshotIdentifier,
        observer: SpoilerRevealStateObserver
    ) {
        var observers = observers[interactionIdentifier] ?? []
        guard !observers.contains(where: {
            $0.value === observer
        }) else {
            return
        }
        observers.append(Weak(value: observer))
        self.observers[interactionIdentifier] = observers
    }

    public func removeObserver(
        for interactionIdentifier: InteractionSnapshotIdentifier,
        observer: SpoilerRevealStateObserver
    ) {
        var observers = observers[interactionIdentifier] ?? []
        observers.removeAll(where: {
            $0.value === observer
        })
        self.observers[interactionIdentifier] = observers
    }

    public typealias Snapshot = [InteractionSnapshotIdentifier: Set<StyleIdType>]

    public func snapshot() -> Snapshot {
        return revealedSpoilerIdsByMessage
    }
}

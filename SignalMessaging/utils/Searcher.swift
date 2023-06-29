//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// A generic searching class, configurable with an indexing block
public class Searcher<T> {

    private let indexer: (T, SDSAnyReadTransaction) -> String

    public init(indexer: @escaping (T, SDSAnyReadTransaction) -> String) {
        self.indexer = indexer
    }

    public func matches(item: T, query: String, transaction: SDSAnyReadTransaction) -> Bool {
        let itemString = normalize(string: indexer(item, transaction))
        return stem(string: query).allSatisfy { queryStem in
            return itemString.contains(queryStem)
        }
    }

    private func stem(string: String) -> [String] {
        var normalized = normalize(string: string)

        // Remove any phone number formatting from the search terms
        let nonformattingScalars = normalized.unicodeScalars.lazy.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }

        normalized = String(String.UnicodeScalarView(nonformattingScalars))

        return normalized.components(separatedBy: .whitespacesAndNewlines)
    }

    private func normalize(string: String) -> String {
        return string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

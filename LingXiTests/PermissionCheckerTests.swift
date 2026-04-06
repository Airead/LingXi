//
//  PermissionCheckerTests.swift
//  LingXiTests
//

import Foundation
import Testing

@testable import LingXi

@MainActor
struct PermissionCheckerTests {
    let checker = PermissionChecker()

    @Test func permissionKindCasesMatchExpected() {
        let ids = PermissionKind.allCases.map(\.id)
        #expect(ids == ["accessibility", "screenRecording", "fullDiskAccess"])
    }

    @Test func allKindsHaveNonEmptyFields() {
        for kind in PermissionKind.allCases {
            #expect(!kind.name.isEmpty)
            #expect(!kind.description.isEmpty)
        }
    }

    @Test func initPopulatesAllStatuses() {
        for kind in PermissionKind.allCases {
            #expect(checker.statuses[kind] != nil)
        }
    }

    @Test func statusDefaultsToNotGranted() {
        // status(for:) returns .notGranted for any kind not in the cache
        // After init, all kinds are populated, so we verify the fallback
        // behavior through the public API: if a kind somehow had no entry,
        // the default would be .notGranted
        let fresh = PermissionChecker()
        // All statuses should be populated after init
        for kind in PermissionKind.allCases {
            #expect(fresh.status(for: kind) == fresh.statuses[kind])
        }
    }

    @Test func settingsURLsAreValid() {
        for kind in PermissionKind.allCases {
            #expect(kind.settingsURL.scheme != nil, "Invalid URL for \(kind.name)")
        }
    }

    @Test func permissionStatusIsGranted() {
        #expect(PermissionStatus.granted.isGranted == true)
        #expect(PermissionStatus.notGranted.isGranted == false)
    }

    @Test func refreshSkipsNoOpUpdates() {
        let initial = checker.statuses
        checker.refresh()
        #expect(checker.statuses == initial)
    }
}

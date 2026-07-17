//
//  IslandGeometryTests.swift
//  AriNotchTests
//
//  WS-H unit tests for the PURE island geometry + presentation math
//  (`IslandGeometry`, `IslandPresentation`). No AppKit / no display — these
//  cover exactly the code the human's visual pass can't: centering math
//  (including multi-monitor origin offsets), top-edge flushness, notch-width
//  derivation, and the state mapping.
//

import XCTest
import CoreGraphics
@testable import ari_notch

final class IslandGeometryTests: XCTestCase {

    // MARK: - islandFrame: centering + top-flush

    func testIslandFrameCentersOnPrimaryScreen() {
        // 1512×982 built-in display at origin (0,0).
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let content = CGSize(width: 200, height: 32)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        // Horizontally centered: midX 756 → x = 756 - 100 = 656.
        XCTAssertEqual(frame.origin.x, 656, accuracy: 0.001)
        // Top edge flush to screen top (maxY 982): y = 982 - 32 = 950.
        XCTAssertEqual(frame.origin.y, 950, accuracy: 0.001)
        XCTAssertEqual(frame.width, 200, accuracy: 0.001)
        XCTAssertEqual(frame.height, 32, accuracy: 0.001)
        // The island's TOP edge must sit exactly at the screen top.
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
    }

    func testIslandFrameCentersOnOffsetSecondaryScreen() {
        // External monitor to the RIGHT of the laptop: origin x = 1512.
        // Proves the math centers on THAT screen, not the global (0,0) origin.
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let content = CGSize(width: 380, height: 180)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        // midX = 1512 + 1280 = 2792 → x = 2792 - 190 = 2602.
        XCTAssertEqual(frame.origin.x, 2602, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 1440 - 180, accuracy: 0.001)
        // Center of the island == center of the screen, horizontally.
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
    }

    func testIslandFrameHandlesNegativeOriginScreen() {
        // Monitor to the LEFT / above: negative origin.
        let screen = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let content = CGSize(width: 300, height: 40)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
    }

    // MARK: - notchWidth

    func testNotchWidthPresent() {
        // 1512-wide screen, ~180pt notch: aux areas 666 + 666 flank it.
        let w = IslandGeometry.notchWidth(
            screenWidth: 1512,
            leftAuxWidth: 666,
            rightAuxWidth: 666
        )
        XCTAssertNotNil(w)
        XCTAssertEqual(w!, 180, accuracy: 0.001)
    }

    func testNotchWidthAbsentWhenAuxSpansWholeWidth() {
        // Non-notched external monitor: no notch → aux areas span full width,
        // leaving ~0 → nil.
        let w = IslandGeometry.notchWidth(
            screenWidth: 2560,
            leftAuxWidth: 1280,
            rightAuxWidth: 1280
        )
        XCTAssertNil(w)
    }

    func testNotchWidthAbsentWhenZeroAux() {
        // No aux info at all collapses to full width, which is NOT a notch.
        let w = IslandGeometry.notchWidth(
            screenWidth: 1440,
            leftAuxWidth: 720,
            rightAuxWidth: 720
        )
        XCTAssertNil(w)
    }

    // MARK: - IslandPresentation mapping

    func testPresentationIdleIsHidden() {
        // Transient surface: idle → hidden (the island disappears after Stop).
        XCTAssertEqual(
            IslandPresentation.derive(isRecording: false, hasUpcoming: false),
            .hidden
        )
    }

    func testPresentationRecordingIsExpanded() {
        XCTAssertEqual(
            IslandPresentation.derive(isRecording: true, hasUpcoming: false),
            .expanded
        )
    }

    func testPresentationUpcomingIsExpanded() {
        XCTAssertEqual(
            IslandPresentation.derive(isRecording: false, hasUpcoming: true),
            .expanded
        )
    }

    func testPresentationRecordingAndUpcomingIsExpanded() {
        XCTAssertEqual(
            IslandPresentation.derive(isRecording: true, hasUpcoming: true),
            .expanded
        )
    }
}

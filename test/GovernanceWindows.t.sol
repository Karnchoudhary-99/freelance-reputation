// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Configurable governance windows: the owner may retune the
///         dispute window (30 days), the escalation delay (7 days) and
///         the appeal window (7 days). Retunes apply live — to open
///         disputes and upheld resolutions — from each record's own
///         timestamp, and the ordering rule (escalation delay always
///         shorter than the dispute window) keeps escalation reachable.
contract GovernanceWindowsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    // Fixed base time so warps read like calendar dates.
    uint64 constant T0 = 1_700_000_000;

    event DisputeWindowUpdated(uint256 disputeWindow);
    event EscalationDelayUpdated(uint256 escalationDelay);
    event AppealWindowUpdated(uint256 appealWindow);

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
    }

    function _attest(
        address attester,
        address subject,
        uint8 score
    ) internal returns (uint256) {
        vm.prank(attester);
        return
            registry.attest(
                subject,
                ReputationRegistry.Category.Overall,
                score,
                bytes32(0)
            );
    }

    /// @notice bob 90 on alice; alice disputes it. Returns bob's id.
    function _disputedId() internal returns (uint256) {
        uint256 id = _attest(bob, alice, 90);
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        return id;
    }

    /// @notice Like `_disputedId`, but bob upholds the dispute, so the
    ///         subject's appeal window opens. Returns bob's id.
    function _upheldId() internal returns (uint256) {
        uint256 id = _disputedId();
        vm.prank(bob);
        registry.resolveDispute(id, true);
        return id;
    }

    function testDefaultsMatchDocumentedValues() public view {
        assertEq(registry.disputeWindow(), 30 days);
        assertEq(registry.escalationDelay(), 7 days);
        assertEq(registry.appealWindow(), 7 days);
        assertEq(registry.DEFAULT_DISPUTE_WINDOW(), 30 days);
        assertEq(registry.DEFAULT_ESCALATION_DELAY(), 7 days);
        assertEq(registry.DEFAULT_APPEAL_WINDOW(), 7 days);
    }

    function testSetDisputeWindowOwnerGuardAndEvent() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setDisputeWindow(10 days);

        vm.expectEmit(false, false, false, true, address(registry));
        emit DisputeWindowUpdated(10 days);
        registry.setDisputeWindow(10 days);
        assertEq(registry.disputeWindow(), 10 days);
    }

    function testSetDisputeWindowBounds() public {
        // Below the 1-day floor.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setDisputeWindow(23 hours);

        // Above the 365-day ceiling.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setDisputeWindow(366 days);

        // At or below the escalation delay (7 days) — escalation
        // could never fire before the window lapses.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setDisputeWindow(7 days);

        // Just above the delay, and the ceiling, both land.
        registry.setDisputeWindow(8 days);
        assertEq(registry.disputeWindow(), 8 days);
        registry.setDisputeWindow(365 days);
        assertEq(registry.disputeWindow(), 365 days);
    }

    function testSetEscalationDelayOwnerGuardAndEvent() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setEscalationDelay(2 days);

        vm.expectEmit(false, false, false, true, address(registry));
        emit EscalationDelayUpdated(2 days);
        registry.setEscalationDelay(2 days);
        assertEq(registry.escalationDelay(), 2 days);
    }

    function testSetEscalationDelayBounds() public {
        // Below the 1-hour floor.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setEscalationDelay(59 minutes);

        // Above the 30-day ceiling.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setEscalationDelay(31 days);

        // At or above the dispute window (30 days) — the dispute
        // would expire before it could ever be escalated.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setEscalationDelay(30 days);

        // The floor and the ceiling both land.
        registry.setEscalationDelay(1 hours);
        assertEq(registry.escalationDelay(), 1 hours);
        registry.setEscalationDelay(29 days);
        assertEq(registry.escalationDelay(), 29 days);
    }

    function testSetAppealWindowOwnerGuardAndEvent() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setAppealWindow(14 days);

        vm.expectEmit(false, false, false, true, address(registry));
        emit AppealWindowUpdated(14 days);
        registry.setAppealWindow(14 days);
        assertEq(registry.appealWindow(), 14 days);
    }

    function testSetAppealWindowBounds() public {
        // Below the 1-day floor.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setAppealWindow(23 hours);

        // Above the 90-day ceiling.
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setAppealWindow(91 days);

        // The floor and the ceiling both land.
        registry.setAppealWindow(1 days);
        assertEq(registry.appealWindow(), 1 days);
        registry.setAppealWindow(90 days);
        assertEq(registry.appealWindow(), 90 days);
    }

    function testRetuneOrderingRule() public {
        // Raising the delay to 20 days is fine against the 30-day
        // window — but then the window cannot drop to 15 days.
        registry.setEscalationDelay(20 days);
        vm.expectRevert(
            ReputationRegistry.InvalidGovernanceWindow.selector
        );
        registry.setDisputeWindow(15 days);

        // Lower the delay first, then the window may follow.
        registry.setEscalationDelay(5 days);
        registry.setDisputeWindow(15 days);
        assertEq(registry.disputeWindow(), 15 days);
        assertEq(registry.escalationDelay(), 5 days);
    }

    function testShorterDisputeWindowLetsSubjectExpireSooner() public {
        uint256 id = _disputedId();
        // Ten days in, the default 30-day window has not lapsed.
        vm.warp(T0 + 10 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.DisputeNotExpired.selector);
        registry.expireDispute(id);

        // Retune the window to 5 days: the same dispute is now
        // expired, because the window runs from its own disputedAt.
        registry.setDisputeWindow(5 days);
        vm.prank(alice);
        registry.expireDispute(id);
        assertFalse(registry.attestation(id).disputed);
    }

    function testLongerDisputeWindowDelaysExpiry() public {
        uint256 id = _disputedId();
        // Thirty-one days in, the default window has lapsed — but
        // retuning to 60 days first keeps the dispute open.
        registry.setDisputeWindow(60 days);
        vm.warp(T0 + 31 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.DisputeNotExpired.selector);
        registry.expireDispute(id);

        vm.warp(T0 + 61 days);
        vm.prank(alice);
        registry.expireDispute(id);
        assertFalse(registry.attestation(id).disputed);
    }

    function testShorterEscalationDelayMakesDisputeEscalatableSooner()
        public
    {
        uint256 id = _disputedId();
        // Two days in, the default 7-day delay has not passed.
        vm.warp(T0 + 2 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.EscalationTooEarly.selector);
        registry.escalateDispute(id);

        // Retune the delay to 1 day: the same dispute is now
        // escalatable, because the delay runs from its disputedAt.
        registry.setEscalationDelay(1 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        assertTrue(registry.isDisputeEscalated(id));
    }

    function testLongerEscalationDelayBlocksEarlyEscalation() public {
        uint256 id = _disputedId();
        // Eight days in, the default delay has passed — but retuning
        // to 10 days first keeps escalation closed.
        registry.setEscalationDelay(10 days);
        vm.warp(T0 + 8 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.EscalationTooEarly.selector);
        registry.escalateDispute(id);

        vm.warp(T0 + 11 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        assertTrue(registry.isDisputeEscalated(id));
    }

    function testAppealStillOpenInsideDefaultWindow() public {
        uint256 id = _upheldId();
        // Three days after the upheld resolution, the default 7-day
        // appeal window is still open.
        vm.warp(T0 + 3 days);
        vm.prank(alice);
        registry.appealDispute(id);
        assertTrue(registry.isAppealed(id));
    }

    function testShorterAppealWindowBlocksLateAppeal() public {
        uint256 id = _upheldId();
        // Retune the window to 2 days: three days after the
        // resolution the appeal is already too late.
        registry.setAppealWindow(2 days);
        vm.warp(T0 + 3 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AppealWindowExpired.selector);
        registry.appealDispute(id);
    }

    function testLongerAppealWindowReopensLapsedAppeal() public {
        uint256 id = _upheldId();
        // Eight days after the resolution, the default window has
        // lapsed — but retuning to 30 days reopens it, because the
        // window runs from the resolution time.
        registry.setAppealWindow(30 days);
        vm.warp(T0 + 8 days);
        vm.prank(alice);
        registry.appealDispute(id);
        assertTrue(registry.isAppealed(id));
    }

    function testAppealDeadlineFollowsRetunedWindow() public {
        uint256 id = _upheldId();
        assertEq(registry.appealDeadline(id), T0 + 7 days);
        registry.setAppealWindow(14 days);
        assertEq(registry.appealDeadline(id), T0 + 14 days);
        registry.setAppealWindow(1 days);
        assertEq(registry.appealDeadline(id), T0 + 1 days);
    }

    function testWindowsSurvivePause() public {
        // Retunes are owner admin, and dispute exits stay open while
        // paused — so a retune mid-pause still governs the exits.
        uint256 id = _disputedId();
        registry.pause();
        registry.setDisputeWindow(5 days);
        vm.warp(T0 + 6 days);
        vm.prank(alice);
        registry.expireDispute(id);
        assertFalse(registry.attestation(id).disputed);
    }

    function testCarolAttestationUnaffectedByWindowRetune() public {
        // A retune moves deadlines, never records: carol's separate
        // attestation on alice is untouched by the window changes.
        _attest(carol, alice, 100);
        uint256 id = _disputedId();
        registry.setDisputeWindow(5 days);
        registry.setEscalationDelay(1 days);
        registry.setAppealWindow(14 days);
        assertEq(registry.getScore(alice).average, 10000);
        assertEq(registry.getScore(alice).count, 1);
        assertEq(registry.attestation(id).score, 90);
    }
}

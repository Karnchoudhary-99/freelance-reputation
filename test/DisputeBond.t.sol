// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice A contract attester whose receive() tries to re-enter the
///         registry mid-payout: it attempts to open a second dispute
///         (as the subject of another attestation) from inside the
///         bond payment it just received. The reentrancy guard must
///         make that inner call revert, so the outer settlement still
///         lands exactly once.
contract ReentrantAttester {
    ReputationRegistry public registry;
    bool public armed;
    bool public reentrySucceeded;
    uint256 public targetId;

    constructor(ReputationRegistry _registry) {
        registry = _registry;
    }

    function attest(
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) external returns (uint256) {
        return registry.attest(subject, category, score, bytes32(0));
    }

    function resolve(uint256 id, bool uphold) external {
        registry.resolveDispute(id, uphold);
    }

    function arm(uint256 id) external {
        armed = true;
        targetId = id;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            try
                registry.disputeAttestation{value: 0.01 ether}(
                    targetId,
                    bytes32("reenter")
                )
            {
                reentrySucceeded = true;
            } catch {}
        }
    }
}

/// @notice Dispute bonds: with a bond configured, opening a dispute
///         stakes exactly that much ETH. The bond goes to the attester
///         when the dispute is upheld and back to the subject when it
///         is conceded, expires, or the attestation is revoked while
///         disputed. Bonds are opt-in — the default is 0, so disputes
///         stay free until the owner sets a bond.
contract DisputeBondTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice"); // subject
    address bob = makeAddr("bob"); // attester
    address carol = makeAddr("carol"); // second attester

    uint256 constant BOND = 0.01 ether;

    event DisputeBondUpdated(uint256 disputeBond);
    event DisputeBondSettled(
        uint256 indexed id,
        address indexed recipient,
        uint256 amount
    );

    function setUp() public {
        registry = new ReputationRegistry();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    /// @notice bob attests alice 90 (Overall); returns the id (0).
    function _attest() internal returns (uint256) {
        vm.prank(bob);
        return
            registry.attest(
                alice,
                ReputationRegistry.Category.Overall,
                90,
                bytes32("v1")
            );
    }

    /// @notice alice disputes `id`, staking the configured bond.
    function _dispute(uint256 id) internal {
        vm.prank(alice);
        registry.disputeAttestation{value: BOND}(id, bytes32("unfair"));
    }

    function testDefaultBondIsZeroAndDisputesAreFree() public {
        assertEq(registry.disputeBond(), 0);
        assertEq(registry.MAX_DISPUTE_BOND(), 1 ether);

        uint256 id = _attest();
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));

        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertTrue(registry.attestation(id).disputed);
    }

    function testSetDisputeBondOwnerOnlyAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setDisputeBond(BOND);

        vm.expectRevert(ReputationRegistry.InvalidDisputeBond.selector);
        registry.setDisputeBond(1 ether + 1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeBondUpdated(BOND);
        registry.setDisputeBond(BOND);
        assertEq(registry.disputeBond(), BOND);

        // The cap itself is a legal bond.
        registry.setDisputeBond(1 ether);
        assertEq(registry.disputeBond(), 1 ether);
    }

    function testDisputeRequiresExactBond() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.IncorrectDisputeBond.selector);
        registry.disputeAttestation(id, bytes32("unfair"));

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.IncorrectDisputeBond.selector);
        registry.disputeAttestation{value: BOND / 2}(id, bytes32("unfair"));

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.IncorrectDisputeBond.selector);
        registry.disputeAttestation{value: BOND * 2}(id, bytes32("unfair"));

        // The exact-value dispute opens cleanly and escrows the bond.
        _dispute(id);
        assertEq(registry.disputeBondOf(id), BOND);
        assertEq(address(registry).balance, BOND);
        assertEq(alice.balance, 10 ether - BOND);
    }

    function testUpholdPaysAttester() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        uint256 bobBefore = bob.balance;
        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeBondSettled(id, bob, BOND);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        assertEq(bob.balance, bobBefore + BOND);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertFalse(registry.attestation(id).disputed);
    }

    function testConcedeRefundsSubject() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);
        assertEq(alice.balance, 10 ether - BOND);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeBondSettled(id, alice, BOND);
        vm.prank(bob);
        registry.resolveDispute(id, false);

        assertEq(alice.balance, 10 ether);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertTrue(registry.attestation(id).revoked);
    }

    function testExpireDisputeRefundsSubject() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        registry.expireDispute(id);

        assertEq(alice.balance, 10 ether);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertFalse(registry.attestation(id).disputed);
    }

    function testRevokeWhileDisputedRefundsSubject() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        vm.prank(bob);
        registry.revokeAttestation(id);

        assertEq(alice.balance, 10 ether);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertTrue(registry.attestation(id).revoked);
    }

    function testOwnerArbitrationUpholdPaysAttester() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        uint256 bobBefore = bob.balance;
        registry.resolveDisputeAsOwner(id, true);

        assertEq(bob.balance, bobBefore + BOND);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
    }

    function testOwnerArbitrationConcedeRefundsSubject() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        registry.resolveDisputeAsOwner(id, false);

        assertEq(alice.balance, 10 ether);
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
        assertTrue(registry.attestation(id).revoked);
    }

    function testBondRetuneDoesNotRepricePostedBond() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);

        // Retune after the dispute opened: the posted bond stays 0.01.
        registry.setDisputeBond(0.05 ether);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        registry.resolveDispute(id, true);

        assertEq(bob.balance, bobBefore + BOND);
        assertEq(address(registry).balance, 0);
    }

    function testDisablingBondMakesDisputesFreeAgain() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        registry.setDisputeBond(0);
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("again"));
        assertEq(registry.disputeBondOf(id), 0);
        assertEq(address(registry).balance, 0);
    }

    function testRedisputePostsFreshBond() public {
        registry.setDisputeBond(BOND);
        uint256 id = _attest();
        _dispute(id);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        _dispute(id);
        assertEq(registry.disputeBondOf(id), BOND);
        assertEq(address(registry).balance, BOND);
        // The first bond went to bob on uphold, so alice is down two
        // bonds now: one lost, one freshly posted.
        assertEq(alice.balance, 10 ether - 2 * BOND);
    }

    function testDisputeBondOfUnknownReverts() public {
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.disputeBondOf(99);
    }

    function testReentrancyGuardBlocksReentryDuringPayout() public {
        registry.setDisputeBond(BOND);
        ReentrantAttester attester = new ReentrantAttester(registry);
        vm.deal(address(attester), 1 ether);

        // id 0: the contract attests alice; alice disputes it.
        uint256 id0 = attester.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90
        );
        vm.prank(alice);
        registry.disputeAttestation{value: BOND}(id0, bytes32("unfair"));

        // id 1: carol attests the contract, so the contract is the
        // subject and may dispute it — the re-entry target.
        vm.prank(carol);
        uint256 id1 = registry.attest(
            address(attester),
            ReputationRegistry.Category.Overall,
            50,
            bytes32("v1")
        );

        attester.arm(id1);
        uint256 attesterBefore = address(attester).balance;
        attester.resolve(id0, true);

        // The inner dispute reverted on the guard: no second dispute
        // opened, no second bond posted, and the outer payout landed
        // exactly once.
        assertFalse(attester.reentrySucceeded());
        assertFalse(registry.attestation(id1).disputed);
        assertEq(registry.disputeBondOf(id1), 0);
        assertEq(address(attester).balance, attesterBefore + BOND);
        assertEq(address(registry).balance, 0);
    }
}

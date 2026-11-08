// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The minimal registry surface a consumer contract needs:
///         the overall score and the tier. Declared against the ABI,
///         not the implementation, so a consumer never imports the
///         registry itself. `tierOf` returns the tier as a uint8
///         (Unranked 0, Emerging 1, Established 2, Trusted 3, Elite 4).
interface IReputationRegistry {
    function getScore(
        address subject
    )
        external
        view
        returns (
            uint256 average,
            uint256 count,
            uint256 totalWeight,
            uint256 effectiveWeight
        );

    function tierOf(address subject) external view returns (uint8);
}

/// @notice Example consumer contract: gate an action on a freelancer's
///         on-chain reputation. A marketplace, for example, can require
///         Established tier + a minimum average before a freelancer may
///         bid on premium jobs. The thresholds are set at deploy time
///         and retunable by the owner; the registry address is immutable
///         — a gate pointed at a different registry is a different gate.
///         This is an integration example, not production access
///         control: it reads reputation, it does not manage funds.
contract ReputationGate {
    IReputationRegistry public immutable registry;
    address public owner;

    uint8 public minTier;
    uint256 public minAverage;

    event ThresholdsUpdated(uint8 minTier, uint256 minAverage);
    event GatedActionCalled(address indexed subject);

    error NotOwner();
    error NotEligible();
    error InvalidThreshold();

    constructor(
        address registry_,
        uint8 minTier_,
        uint256 minAverage_
    ) {
        if (registry_ == address(0)) revert InvalidThreshold();
        if (minTier_ > 4) revert InvalidThreshold();
        if (minAverage_ > 10000) revert InvalidThreshold();
        registry = IReputationRegistry(registry_);
        owner = msg.sender;
        minTier = minTier_;
        minAverage = minAverage_;
    }

    /// @notice True when the subject clears both bars right now:
    ///         tier at or above `minTier`, and overall average (scaled
    ///         by 100) at or above `minAverage`. A subject with no
    ///         attestations is Unranked with average 0, so they fail
    ///         every non-trivial gate.
    function isEligible(address subject) public view returns (bool) {
        if (registry.tierOf(subject) < minTier) return false;
        (uint256 average, , , ) = registry.getScore(subject);
        return average >= minAverage;
    }

    /// @notice The gated action itself: reverts for ineligible
    ///         subjects, emits an event for eligible ones. A real
    ///         marketplace would do its work here (accept a bid, open
    ///         a premium listing) instead of just logging.
    function gatedAction(address subject) external {
        if (!isEligible(subject)) revert NotEligible();
        emit GatedActionCalled(subject);
    }

    /// @notice Retune the bars. Owner-only; lowering them never
    ///         rewrites anyone's reputation, it only changes who the
    ///         gate admits from now on.
    function setThresholds(uint8 minTier_, uint256 minAverage_) external {
        if (msg.sender != owner) revert NotOwner();
        if (minTier_ > 4) revert InvalidThreshold();
        if (minAverage_ > 10000) revert InvalidThreshold();
        minTier = minTier_;
        minAverage = minAverage_;
        emit ThresholdsUpdated(minTier_, minAverage_);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title RWAOracleRegistry
 * @notice Multi-attestor oracle registry for real-world-asset observations.
 * @dev A report proves that authorized attestors signed the same structured
 *      observation. It does not create legal title or independently prove that
 *      the offchain claim is true.
 */
contract RWAOracleRegistry is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "Report(bytes32 feedId,uint64 roundId,int192 value,uint64 observedAt,uint64 validUntil,bytes32 evidenceHash)"
    );

    struct FeedConfig {
        uint8 decimals;
        uint8 quorum;
        uint64 maxAge;
        uint32 maxDeviationBps;
        int192 minValue;
        int192 maxValue;
        bytes32 metadataHash;
    }

    struct FeedState {
        address controller;
        address pendingController;
        uint64 latestRoundId;
        bool paused;
        bool exists;
        FeedConfig config;
    }

    struct Report {
        bytes32 feedId;
        uint64 roundId;
        int192 value;
        uint64 observedAt;
        uint64 validUntil;
        bytes32 evidenceHash;
    }

    struct SignedReport {
        address reporter;
        bytes signature;
    }

    struct Round {
        int192 value;
        uint64 observedAt;
        uint64 acceptedAt;
        bytes32 evidenceHash;
        uint8 signerCount;
        bool invalidated;
    }

    struct Dispute {
        uint64 roundId;
        bytes32 reasonHash;
        bytes32 resolutionHash;
        uint64 openedAt;
        uint64 resolvedAt;
        bool open;
        bool invalidated;
    }

    mapping(bytes32 => FeedState) private _feeds;
    mapping(bytes32 => mapping(address => bool)) public isReporter;
    mapping(bytes32 => mapping(uint64 => Round)) private _rounds;
    mapping(bytes32 => Dispute) private _disputes;

    error FeedAlreadyExists();
    error FeedNotFound();
    error NotFeedController();
    error InvalidConfiguration();
    error FeedIsPaused();
    error InvalidRound();
    error InvalidTimestamp();
    error InvalidEvidence();
    error QuorumNotMet();
    error UnauthorizedReporter();
    error ReporterOrderInvalid();
    error InvalidSignature();
    error ValueOutOfBounds();
    error DeviationTooLarge();
    error NoOpenDispute();
    error DisputeAlreadyOpen();
    error NotPendingController();

    event FeedCreated(
        bytes32 indexed feedId,
        address indexed controller,
        uint8 decimals,
        uint8 quorum,
        uint64 maxAge,
        bytes32 metadataHash
    );
    event FeedConfigurationUpdated(bytes32 indexed feedId, FeedConfig config);
    event ReporterSet(bytes32 indexed feedId, address indexed reporter, bool enabled);
    event ControllerTransferProposed(bytes32 indexed feedId, address indexed currentController, address indexed pendingController);
    event ControllerTransferred(bytes32 indexed feedId, address indexed oldController, address indexed newController);
    event RoundAccepted(
        bytes32 indexed feedId,
        uint64 indexed roundId,
        int192 value,
        uint64 observedAt,
        uint64 acceptedAt,
        bytes32 evidenceHash,
        uint8 signerCount
    );
    event FeedPauseChanged(bytes32 indexed feedId, bool paused, address indexed actor);
    event DisputeOpened(bytes32 indexed feedId, uint64 indexed roundId, bytes32 reasonHash, address indexed actor);
    event DisputeResolved(
        bytes32 indexed feedId,
        uint64 indexed roundId,
        bool invalidated,
        bytes32 resolutionHash,
        address indexed actor
    );

    constructor(address admin, address guardian) EIP712("Oracle1 RWA Registry", "1") {
        if (admin == address(0) || guardian == address(0)) revert InvalidConfiguration();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    modifier onlyFeedController(bytes32 feedId) {
        FeedState storage feed = _feeds[feedId];
        if (!feed.exists) revert FeedNotFound();
        if (msg.sender != feed.controller && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotFeedController();
        }
        _;
    }

    function createFeed(bytes32 feedId, FeedConfig calldata config) external {
        _createFeed(feedId, msg.sender, config);
    }

    function createFeedFor(bytes32 feedId, address controller, FeedConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _createFeed(feedId, controller, config);
    }

    function _createFeed(bytes32 feedId, address controller, FeedConfig calldata config) internal {
        if (_feeds[feedId].exists) revert FeedAlreadyExists();
        if (feedId == bytes32(0) || controller == address(0)) revert InvalidConfiguration();
        _validateConfiguration(config);
        FeedState storage feed = _feeds[feedId];
        feed.controller = controller;
        feed.exists = true;
        feed.config = config;
        emit FeedCreated(feedId, controller, config.decimals, config.quorum, config.maxAge, config.metadataHash);
    }

    function updateFeedConfiguration(bytes32 feedId, FeedConfig calldata config)
        external
        onlyFeedController(feedId)
    {
        _validateConfiguration(config);
        FeedState storage feed = _feeds[feedId];
        if (feed.latestRoundId != 0 && config.decimals != feed.config.decimals) {
            revert InvalidConfiguration();
        }
        feed.config = config;
        emit FeedConfigurationUpdated(feedId, config);
    }

    function setReporter(bytes32 feedId, address reporter, bool enabled)
        external
        onlyFeedController(feedId)
    {
        if (reporter == address(0)) revert InvalidConfiguration();
        isReporter[feedId][reporter] = enabled;
        emit ReporterSet(feedId, reporter, enabled);
    }

    function proposeController(bytes32 feedId, address newController)
        external
        onlyFeedController(feedId)
    {
        if (newController == address(0)) revert InvalidConfiguration();
        FeedState storage feed = _feeds[feedId];
        feed.pendingController = newController;
        emit ControllerTransferProposed(feedId, feed.controller, newController);
    }

    function acceptController(bytes32 feedId) external {
        FeedState storage feed = _feeds[feedId];
        if (!feed.exists) revert FeedNotFound();
        if (feed.pendingController != msg.sender) revert NotPendingController();
        address oldController = feed.controller;
        feed.controller = msg.sender;
        feed.pendingController = address(0);
        emit ControllerTransferred(feedId, oldController, msg.sender);
    }

    function submitRound(Report calldata report, SignedReport[] calldata signedReports)
        external
        whenNotPaused
        nonReentrant
    {
        FeedState storage feed = _feeds[report.feedId];
        if (!feed.exists) revert FeedNotFound();
        if (feed.paused) revert FeedIsPaused();
        if (report.roundId != feed.latestRoundId + 1) revert InvalidRound();
        if (report.evidenceHash == bytes32(0)) revert InvalidEvidence();
        if (
            report.observedAt > block.timestamp + 5 minutes ||
            report.observedAt + feed.config.maxAge < block.timestamp ||
            report.validUntil < block.timestamp ||
            report.validUntil < report.observedAt
        ) revert InvalidTimestamp();
        if (report.value < feed.config.minValue || report.value > feed.config.maxValue) {
            revert ValueOutOfBounds();
        }
        if (signedReports.length < feed.config.quorum || signedReports.length > type(uint8).max) {
            revert QuorumNotMet();
        }

        if (feed.latestRoundId != 0 && feed.config.maxDeviationBps != 0) {
            int192 previous = _rounds[report.feedId][feed.latestRoundId].value;
            uint256 previousAbsolute = _absolute(previous);
            if (previousAbsolute != 0) {
                uint256 difference = _absoluteDifference(report.value, previous);
                if (difference * 10_000 > previousAbsolute * feed.config.maxDeviationBps) {
                    revert DeviationTooLarge();
                }
            }
        }

        bytes32 digest = reportDigest(report);
        address previousReporter = address(0);
        for (uint256 index = 0; index < signedReports.length; ++index) {
            SignedReport calldata signed = signedReports[index];
            if (uint160(signed.reporter) <= uint160(previousReporter)) revert ReporterOrderInvalid();
            if (!isReporter[report.feedId][signed.reporter]) revert UnauthorizedReporter();
            if (!SignatureChecker.isValidSignatureNow(signed.reporter, digest, signed.signature)) {
                revert InvalidSignature();
            }
            previousReporter = signed.reporter;
        }

        uint64 acceptedAt = uint64(block.timestamp);
        _rounds[report.feedId][report.roundId] = Round({
            value: report.value,
            observedAt: report.observedAt,
            acceptedAt: acceptedAt,
            evidenceHash: report.evidenceHash,
            signerCount: uint8(signedReports.length),
            invalidated: false
        });
        feed.latestRoundId = report.roundId;
        emit RoundAccepted(
            report.feedId,
            report.roundId,
            report.value,
            report.observedAt,
            acceptedAt,
            report.evidenceHash,
            uint8(signedReports.length)
        );
    }

    function reportDigest(Report calldata report) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REPORT_TYPEHASH,
                    report.feedId,
                    report.roundId,
                    report.value,
                    report.observedAt,
                    report.validUntil,
                    report.evidenceHash
                )
            )
        );
    }

    function setFeedPaused(bytes32 feedId, bool paused) external onlyFeedController(feedId) {
        _feeds[feedId].paused = paused;
        emit FeedPauseChanged(feedId, paused, msg.sender);
    }

    function pauseAll() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpauseAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function openDispute(bytes32 feedId, uint64 roundId, bytes32 reasonHash) external {
        FeedState storage feed = _feeds[feedId];
        if (!feed.exists) revert FeedNotFound();
        if (
            msg.sender != feed.controller &&
            !hasRole(GUARDIAN_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) revert NotFeedController();
        if (reasonHash == bytes32(0) || roundId == 0 || roundId > feed.latestRoundId) {
            revert InvalidConfiguration();
        }
        Dispute storage dispute = _disputes[feedId];
        if (dispute.open) revert DisputeAlreadyOpen();
        dispute.roundId = roundId;
        dispute.reasonHash = reasonHash;
        dispute.openedAt = uint64(block.timestamp);
        dispute.open = true;
        feed.paused = true;
        emit DisputeOpened(feedId, roundId, reasonHash, msg.sender);
        emit FeedPauseChanged(feedId, true, msg.sender);
    }

    function resolveDispute(bytes32 feedId, bool invalidate, bytes32 resolutionHash)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        Dispute storage dispute = _disputes[feedId];
        if (!dispute.open) revert NoOpenDispute();
        if (resolutionHash == bytes32(0)) revert InvalidEvidence();
        dispute.open = false;
        dispute.invalidated = invalidate;
        dispute.resolutionHash = resolutionHash;
        dispute.resolvedAt = uint64(block.timestamp);
        if (invalidate) _rounds[feedId][dispute.roundId].invalidated = true;
        emit DisputeResolved(feedId, dispute.roundId, invalidate, resolutionHash, msg.sender);
    }

    function latestData(bytes32 feedId)
        external
        view
        returns (
            uint64 roundId,
            int192 value,
            uint8 decimals,
            uint64 observedAt,
            uint64 acceptedAt,
            bytes32 evidenceHash,
            bool usable,
            bool stale,
            bool disputed
        )
    {
        FeedState storage feed = _feeds[feedId];
        if (!feed.exists) revert FeedNotFound();
        roundId = feed.latestRoundId;
        Round storage round = _rounds[feedId][roundId];
        value = round.value;
        decimals = feed.config.decimals;
        observedAt = round.observedAt;
        acceptedAt = round.acceptedAt;
        evidenceHash = round.evidenceHash;
        stale = roundId == 0 || observedAt + feed.config.maxAge < block.timestamp;
        disputed = _disputes[feedId].open || round.invalidated;
        usable = !paused() && !feed.paused && !stale && !disputed;
    }

    function getFeed(bytes32 feedId) external view returns (FeedState memory) {
        if (!_feeds[feedId].exists) revert FeedNotFound();
        return _feeds[feedId];
    }

    function getRound(bytes32 feedId, uint64 roundId) external view returns (Round memory) {
        if (!_feeds[feedId].exists) revert FeedNotFound();
        return _rounds[feedId][roundId];
    }

    function getDispute(bytes32 feedId) external view returns (Dispute memory) {
        if (!_feeds[feedId].exists) revert FeedNotFound();
        return _disputes[feedId];
    }

    function _validateConfiguration(FeedConfig calldata config) internal pure {
        if (
            config.quorum == 0 ||
            config.maxAge < 5 minutes ||
            config.maxAge > 365 days ||
            config.maxDeviationBps > 10_000 ||
            config.minValue >= config.maxValue ||
            config.metadataHash == bytes32(0)
        ) revert InvalidConfiguration();
    }

    function _absolute(int192 value) internal pure returns (uint256) {
        int256 expanded = int256(value);
        return uint256(expanded < 0 ? -expanded : expanded);
    }

    function _absoluteDifference(int192 left, int192 right) internal pure returns (uint256) {
        int256 difference = int256(left) - int256(right);
        return uint256(difference < 0 ? -difference : difference);
    }
}

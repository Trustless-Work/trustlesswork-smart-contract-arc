// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Types, errors and events of the single-release escrow, ported from
/// the Soroban v2 contract (trustlesswork-smart-contract-stellar, `contracts/escrow/src`). Names follow the Rust
/// originals in camelCase; `Option<T>` fields become a `set*` flag + value.
interface ISingleReleaseEscrow {
    ////////////////////////
    // Types /////
    ////////////////////////

    struct MilestoneApprovals {
        uint32 target;
        uint32 approvalCount;
        address[] approvedBy;
    }

    struct Milestone {
        string description;
        string status;
        string evidence;
        MilestoneApprovals approvals;
    }

    struct Roles {
        address[] approvers;
        address[] serviceProviders;
        address platform;
        address[] releaseSigners;
        address[] disputeResolvers;
        address receiver;
        address admin;
        address[] observers;
    }

    struct Dispute {
        bool isDisputed;
        string reason;
        bool resolved;
    }

    /// @dev `token` replaces Soroban's `trustline.address`.
    struct Escrow {
        string engagementId;
        string title;
        Roles roles;
        string description;
        uint256 amount;
        uint32 platformFee;
        Milestone[] milestones;
        Dispute dispute;
        bool released;
        address token;
        uint32 receiverMemo;
    }

    struct MilestoneStatusUpdate {
        uint32 milestoneIndex;
        string newStatus;
        bool setEvidence;
        string newEvidence;
    }

    struct MilestoneUpdate {
        uint32 index;
        bool setDescription;
        string newDescription;
    }

    /// @dev `evidenceHash` is zero when the update left the evidence untouched.
    struct MilestoneStatusEntry {
        uint32 index;
        string status;
        bytes32 evidenceHash;
    }

    /// @dev Which mutable properties an `updateEscrow` call changed.
    struct EscrowPropertyChanges {
        bool engagementId;
        bool title;
        bool description;
        bool amount;
        bool platformFee;
        bool roles;
        bool token;
        bool receiverMemo;
        uint256 oldAmount;
        uint256 newAmount;
        uint32 oldPlatformFee;
        uint32 newPlatformFee;
    }

    struct MilestoneAddedEntry {
        uint32 index;
        bytes32 descriptionHash;
    }

    /// @dev `newDescriptionHash` is zero when the description did not change.
    struct MilestoneUpdatedEntry {
        uint32 index;
        bytes32 newDescriptionHash;
    }

    struct DistributionEntry {
        address recipient;
        uint256 amount;
    }

    struct FeeResult {
        uint256 trustlessWorkFee;
        uint256 platformFee;
        uint256 receiverAmount;
    }

    ////////////////////////
    // Errors /////
    ////////////////////////

    // EscrowError
    error EscrowAlreadyInitialized();
    error EscrowNotFound();
    error EscrowAlreadyReleased();
    error EscrowAlreadyResolved();
    error EscrowAlreadyInDispute();
    error EscrowNotInDispute();
    error EscrowOpenedForDisputeResolution();
    error EscrowNotCompleted();
    error EscrowBalanceNotEnoughToSendEarnings();
    error EscrowPropertiesMismatch();
    error FlagsMustBeFalse();
    error AmountCannotBeZero();
    error PlatformFeeTooHigh();
    error InsufficientFundsForEscrowFunding();
    error TooManyEscrowsRequested();
    error InsufficientFundsForResolution();
    error DistributionsMustEqualEscrowBalance();
    error AmountsToBeTransferredShouldBePositive();
    error TotalAmountCannotBeZero();
    error TooManyDistributions();
    error EscrowNotFullyProcessed();
    error OnlyReleaseSignerCanReleaseEarnings();
    error OnlyDisputeResolverCanExecuteThisFunction();
    error UnauthorizedToChangeDisputeFlag();
    error DisputeResolverCannotDisputeTheEscrow();
    error OnlyAdminAddressExecuteThisFunction();
    error AdminAddressCannotBeChanged();
    error AdminAddressOverlapsWithOtherRole();
    error ApproversListEmpty();
    error ServiceProvidersListEmpty();
    error ReleaseSignersListEmpty();
    error DisputeResolversListEmpty();
    error NoMilestoneDefined();
    error TooManyMilestones();
    error TargetCannotBeZero();
    error PlatformAddressCannotBeChanged();
    error InvalidMilestoneIndex();
    error RoleLimitExceeded();
    error DuplicateAddressInRole();
    error DisputeResolverOverlapsWithOtherRole();
    error MilestoneUpdateNotAllowedWithFunds();
    error TargetExceedsApprovers();
    error StringTooLong();
    error SignerMustBeApproverAndReleaseSigner();

    // MilestoneError (names shared with EscrowError are declared once above)
    error MilestoneHasAlreadyBeenApproved();
    error ApproverAlreadyApprovedMilestone();
    error EmptyMilestoneStatus();
    error MilestoneToApproveDoesNotExist();
    error MilestoneToUpdateDoesNotExist();
    error BatchMilestoneUpdateEmpty();
    error BatchMilestoneApproveEmpty();
    error OnlyServiceProviderCanChangeMilestoneStatus();
    error UnauthorizedApprover();
    error DuplicateMilestoneIndex();
    error BatchTooLarge();

    // EVM-only
    error OnlyFactory();
    error ZeroAddress();
    error DistributionLengthMismatch();
    error DuplicateDistributionRecipient();

    ////////////////////////
    // Events /////
    ////////////////////////

    event EscrowInitialized(
        string indexed engagementId, uint256 amount, uint32 platformFee, address token, address receiver
    );
    event EscrowFunded(string indexed engagementId, address indexed funder, uint256 amount, uint256 fundedTotal);
    event FundsReleased(
        string indexed engagementId,
        address indexed releaseSigner,
        address indexed receiver,
        uint256 amount,
        uint256 platformFee,
        uint256 trustlessWorkFee,
        uint256 netAmount
    );
    event EscrowUpdated(string indexed engagementId, address indexed admin, EscrowPropertyChanges changes);
    event MilestoneStatusChanged(
        string indexed engagementId, address indexed serviceProvider, MilestoneStatusEntry[] updates
    );
    event MilestonesApproved(string indexed engagementId, address indexed approver, uint32[] milestoneIndices);
    event EscrowDisputed(string indexed engagementId, address indexed signer, string reason);
    event DisputeResolved(
        string indexed engagementId,
        address indexed disputeResolver,
        uint256 platformFee,
        uint256 trustlessWorkFee,
        DistributionEntry[] distributions
    );
    event FundsWithdrawn(
        string indexed engagementId,
        address indexed disputeResolver,
        uint256 platformFee,
        uint256 trustlessWorkFee,
        DistributionEntry[] distributions
    );
    event MilestonesManaged(
        string indexed engagementId,
        address indexed admin,
        uint32 addedCount,
        uint32 updatedCount,
        MilestoneAddedEntry[] added,
        MilestoneUpdatedEntry[] updated
    );

    ////////////////////////
    // Functions /////
    ////////////////////////

    function initialize(Escrow calldata escrowProperties) external;

    function fundEscrow(uint256 amount, bytes32 expectedEscrowHash) external;

    function fundEscrowWithPermit(
        uint256 amount,
        bytes32 expectedEscrowHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function releaseFunds() external;

    function updateEscrow(Escrow calldata escrowProperties) external;

    function manageMilestones(Milestone[] calldata newMilestones, MilestoneUpdate[] calldata milestoneUpdates) external;

    function changeMilestoneStatus(MilestoneStatusUpdate[] calldata updates) external;

    function approveMilestones(uint32[] calldata milestoneIndices) external;

    function approveAndReleaseMilestones(uint32[] calldata milestoneIndices) external;

    function disputeEscrow(string calldata reason) external;

    function resolveDispute(address[] calldata recipients, uint256[] calldata amounts) external;

    function withdrawRemainingFunds(address[] calldata recipients, uint256[] calldata amounts) external;

    function getEscrow() external view returns (Escrow memory);

    function escrowHash() external view returns (bytes32);

    function fundedAmount() external view returns (uint256);

    function token() external view returns (address);
}

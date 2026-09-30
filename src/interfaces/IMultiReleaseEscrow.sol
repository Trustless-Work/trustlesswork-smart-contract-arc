// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Types, errors and events of the multi-release escrow, ported from
/// the Soroban v2 contract (`contracts/escrow/src`, branch
/// `multi-release-develop-v2`). Each milestone is a mini-escrow with its own
/// amount, receiver, dispute and release flag. Names follow the Rust originals
/// in camelCase; `Option<T>` fields become a `set*` flag + value.
interface IMultiReleaseEscrow {
    ////////////////////////
    // Types /////
    ////////////////////////

    struct MilestoneApprovals {
        uint32 target;
        uint32 approvalCount;
        address[] approvedBy;
    }

    struct Dispute {
        bool isDisputed;
        string reason;
        bool resolved;
    }

    struct Milestone {
        string description;
        string status;
        string evidence;
        MilestoneApprovals approvals;
        uint256 amount;
        Dispute dispute;
        bool released;
        address receiver;
    }

    /// @dev No `receiver`: each milestone names its own.
    struct Roles {
        address[] approvers;
        address[] serviceProviders;
        address platform;
        address[] releaseSigners;
        address[] disputeResolvers;
        address admin;
        address[] observers;
    }

    /// @dev `token` replaces Soroban's `trustline.address`. There is no
    /// escrow-level amount: the total is the sum of the milestone amounts.
    struct Escrow {
        string engagementId;
        string title;
        Roles roles;
        string description;
        uint32 platformFee;
        Milestone[] milestones;
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
        bool setAmount;
        uint256 newAmount;
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
        bool platformFee;
        bool roles;
        bool token;
        bool receiverMemo;
        uint32 oldPlatformFee;
        uint32 newPlatformFee;
    }

    struct MilestoneAddedEntry {
        uint32 index;
        uint256 amount;
        bytes32 descriptionHash;
    }

    /// @dev Soroban's `Option<i128>`/`Option<BytesN<32>>`: `amountChanged`
    /// flags `newAmount`, and `newDescriptionHash` is zero when unchanged.
    struct MilestoneUpdatedEntry {
        uint32 index;
        bool amountChanged;
        uint256 newAmount;
        bytes32 newDescriptionHash;
    }

    struct DistributionEntry {
        address recipient;
        uint256 amount;
    }

    struct MilestonePayout {
        uint32 index;
        address receiver;
        uint256 amount;
        uint256 platformFee;
        uint256 trustlessWorkFee;
        uint256 netAmount;
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
    error EscrowNotInDispute();
    error EscrowOpenedForDisputeResolution();
    error EscrowNotCompleted();
    error EscrowBalanceNotEnoughToSendEarnings();
    error EscrowPropertiesMismatch();
    error FlagsMustBeFalse();
    error AmountCannotBeZero();
    error PlatformFeeTooHigh();
    error InsufficientFundsForEscrowFunding();
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
    error ReleaseMilestonesEmpty();
    error MilestoneAlreadyReleased();
    error InvalidMilestoneIndex();
    error BatchMilestoneDisputeEmpty();
    error MilestoneAlreadyDisputed();
    error RoleLimitExceeded();
    error DuplicateAddressInRole();
    error DisputeResolverOverlapsWithOtherRole();
    error MilestoneUpdateNotAllowedWithFunds();
    error TargetExceedsApprovers();
    error StringTooLong();
    error SignerMustBeApproverAndReleaseSigner();

    // ReleaseError / MilestoneError (names shared with EscrowError are declared once above)
    error DuplicateMilestoneIndex();
    error BatchTooLarge();
    error MilestoneHasAlreadyBeenApproved();
    error ApproverAlreadyApprovedMilestone();
    error EmptyMilestoneStatus();
    error MilestoneToApproveDoesNotExist();
    error MilestoneToUpdateDoesNotExist();
    error BatchMilestoneUpdateEmpty();
    error BatchMilestoneApproveEmpty();
    error OnlyServiceProviderCanChangeMilestoneStatus();
    error UnauthorizedApprover();
    error MilestoneAlreadyResolved();

    // EVM-only
    error OnlyFactory();
    error ZeroAddress();
    error DistributionLengthMismatch();
    error DuplicateDistributionRecipient();

    ////////////////////////
    // Events /////
    ////////////////////////

    event EscrowInitialized(string indexed engagementId, uint32 milestoneCount, uint256 totalAmount);
    event EscrowFunded(string indexed engagementId, address indexed funder, uint256 amount, uint256 fundedTotal);
    event FundsReleased(string indexed engagementId, address indexed releaseSigner, MilestonePayout[] payouts);
    event EscrowUpdated(string indexed engagementId, address indexed admin, EscrowPropertyChanges changes);
    event MilestoneStatusChanged(
        string indexed engagementId, address indexed serviceProvider, MilestoneStatusEntry[] updates
    );
    event MilestonesApproved(string indexed engagementId, address indexed approver, uint32[] milestoneIndices);
    event MilestonesDisputed(
        string indexed engagementId, address indexed signer, string reason, uint32[] milestoneIndices
    );
    event DisputeResolved(
        string indexed engagementId,
        address indexed disputeResolver,
        uint32[] milestoneIndices,
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

    function releaseFunds(uint32[] calldata milestoneIndices) external;

    function updateEscrow(Escrow calldata escrowProperties) external;

    function manageMilestones(Milestone[] calldata newMilestones, MilestoneUpdate[] calldata milestoneUpdates) external;

    function changeMilestoneStatus(MilestoneStatusUpdate[] calldata updates) external;

    function approveMilestones(uint32[] calldata milestoneIndices) external;

    function approveAndReleaseMilestones(uint32[] calldata milestoneIndices) external;

    function disputeMilestones(uint32[] calldata milestoneIndices, string calldata reason) external;

    function resolveDispute(
        uint32[] calldata milestoneIndices,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external;

    function withdrawRemainingFunds(address[] calldata recipients, uint256[] calldata amounts) external;

    function getEscrow() external view returns (Escrow memory);

    function escrowHash() external view returns (bytes32);

    function fundedAmount() external view returns (uint256);

    function token() external view returns (address);
}

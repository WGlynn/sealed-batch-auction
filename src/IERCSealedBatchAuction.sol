// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// An order sells `sellAmount` of `sellToken` for `buyToken`, and accepts no less than `limitPrice` units of
/// buyToken per unit of sellToken, scaled by 1e18.
struct LimitOrder {
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 limitPrice;
}

enum Phase {
    Commit,
    Reveal,
    Settling,
    Settled
}

enum Rationing {
    ProRata,
    SeededOrder
}

/// Sealed-Bid Batch Auction. A compliant venue also implements ERC-5732's IERC_COMMIT_CORE
/// (`commit(bytes32)`, interface id 0xf14fcbc8) and ERC-165.
interface IERCSealedBatchAuction {
    event Committed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, uint256 deposit);
    event Revealed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, LimitOrder order);
    event Forfeited(uint256 indexed batchId, bytes32 indexed commitment, uint256 forfeited, uint256 refunded);
    /// One per pair that traded. Price is quote per base, scaled by 1e18; base is the lower token address.
    event BatchCleared(
        uint256 indexed batchId,
        address indexed base,
        address indexed quote,
        uint256 price,
        uint256 baseVolume,
        uint256 quoteVolume
    );

    function commit(bytes32 commitment) external payable;
    function reveal(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt) external;
    function settle(uint256 batchId) external;
    function claim(uint256 batchId, bytes32 commitment) external;

    function currentBatch() external view returns (uint256 batchId);
    function schedule(uint256 batchId) external view returns (uint64 commitEnd, uint64 revealEnd, Phase phase);
    function requiredDeposit() external view returns (uint256);
    function forfeitBps() external view returns (uint16);
    function rationing() external view returns (Rationing);
    function commitmentOf(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt)
        external
        view
        returns (bytes32);
}

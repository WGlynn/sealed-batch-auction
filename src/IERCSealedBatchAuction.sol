// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// An order on a pair (base, quote), where base is the lower token address. `limitPrice` is in the pair's price
/// unit, quote per base scaled by priceScale(): the least an order selling base accepts, or the most an order
/// selling quote pays.
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
    Settled,
    Expired
}

enum Rationing {
    ProRata,
    SeededOrder
}

/// Sealed-Bid Batch Auction. A compliant venue also implements ERC-5732's IERC_COMMIT_CORE
/// (`commit(bytes32)`, interface id 0xf14fcbc8) and ERC-165.
interface IERCSealedBatchAuction {
    event Committed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, uint256 deposit);
    /// Emitted for an opened order that was escrowed and will take part in clearing.
    event Revealed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, LimitOrder order);
    /// Emitted when part of a deposit is kept: the commitment was not opened, or opened an order that cannot trade.
    event Forfeited(uint256 indexed batchId, bytes32 indexed commitment, uint256 forfeited, uint256 refunded);
    /// One per pair that traded. Volumes are the amounts taken from sellers of each token.
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
    function schedule(uint256 batchId)
        external
        view
        returns (uint64 commitEnd, uint64 revealEnd, uint64 settleEnd, Phase phase);
    function requiredDeposit() external view returns (uint256);
    function forfeitBps() external view returns (uint16);
    function rationing() external view returns (Rationing);
    function priceScale() external view returns (uint256);
    function tieToleranceBps() external view returns (uint16);
    function maxCommitments() external view returns (uint32);
    function minSellAmount(address token) external view returns (uint256);
    function commitmentOf(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt)
        external
        view
        returns (bytes32);
}

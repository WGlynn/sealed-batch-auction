// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERCSealedBatchAuction, LimitOrder, Phase, Rationing} from "./IERCSealedBatchAuction.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SealedBatchAuction
/// @notice Reference implementation of the Sealed-Bid Batch Auction ERC for one token pair.
/// @dev Written for clarity, not gas. Settlement is O(n^2) in the orders of a batch, so the number of
///      commitments per batch is capped. Not audited.
contract SealedBatchAuction is IERCSealedBatchAuction {
    // ============ Constants ============

    uint256 private constant ONE = 1e18;
    uint256 private constant ONE_SQUARED = 1e36;

    bytes32 public constant TYPEHASH = keccak256(
        "SealedBatchOrder(uint256 chainId,address venue,uint256 batchId,address committer,LimitOrder order,bytes32 salt)"
        "LimitOrder(address sellToken,address buyToken,uint256 sellAmount,uint256 limitPrice)"
    );

    bytes4 private constant ERC5732_COMMIT_CORE = 0xf14fcbc8;
    bytes4 private constant ERC165 = 0x01ffc9a7;

    // ============ Configuration ============

    address public immutable base; // the lower token address of the pair
    address public immutable quote; // the higher token address of the pair
    uint64 public immutable genesis; // block number at which batch 0 opens
    uint64 public immutable commitBlocks;
    uint64 public immutable revealBlocks;
    uint256 public immutable deposit;
    uint16 public immutable forfeit; // basis points of the deposit kept from an unrevealed commitment
    uint32 public immutable maxCommits; // per batch
    address public immutable sink; // receives forfeits and rounding dust; never a trader or the settler

    // ============ State ============

    enum Status {
        None,
        Committed,
        Revealed,
        Unsupported
    }

    struct Commitment {
        address committer;
        uint64 batchId;
        Status status;
        bool claimed;
        LimitOrder order;
        uint256 sold; // units of order.sellToken delivered at settlement
        uint256 bought; // units of order.buyToken received at settlement
    }

    struct Batch {
        uint32 commits;
        bool settled;
        uint256 price; // quote per base, 1e18; 0 if the batch did not clear
    }

    mapping(bytes32 => Commitment) internal _commitments;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => bytes32[]) internal _revealed;

    uint256 public sinkEth;
    mapping(address => uint256) public sinkTokens;

    uint256 private _lock = 1;

    // ============ Errors ============

    error WrongPhase();
    error BadDeposit();
    error BatchFull();
    error DuplicateCommitment();
    error UnknownCommitment();
    error NotCommitter();
    error AlreadyRevealed();
    error BadOrder();
    error EscrowShort();
    error AlreadySettled();
    error NotClaimable();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address tokenA,
        address tokenB,
        uint64 commitBlocks_,
        uint64 revealBlocks_,
        uint256 deposit_,
        uint16 forfeitBps_,
        uint32 maxCommits_,
        address sink_
    ) {
        require(tokenA != tokenB && tokenA != address(0) && tokenB != address(0), "pair");
        require(commitBlocks_ > 0 && revealBlocks_ >= 2, "windows");
        require(forfeitBps_ <= 10_000 && maxCommits_ > 0 && sink_ != address(0), "params");
        (base, quote) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        genesis = uint64(block.number);
        commitBlocks = commitBlocks_;
        revealBlocks = revealBlocks_;
        deposit = deposit_;
        forfeit = forfeitBps_;
        maxCommits = maxCommits_;
        sink = sink_;
    }

    // ============ Schedule ============

    /// @dev Batch k accepts commitments in blocks [genesis + k*C, genesis + (k+1)*C - 1] and reveals in the
    ///      R blocks after that. Batches overlap: batch k reveals while batch k+1 takes commitments.
    function schedule(uint256 batchId) public view returns (uint64 commitEnd, uint64 revealEnd, Phase phase) {
        commitEnd = uint64(genesis + (batchId + 1) * commitBlocks - 1);
        revealEnd = commitEnd + revealBlocks;
        if (block.number <= commitEnd) phase = Phase.Commit;
        else if (block.number <= revealEnd) phase = Phase.Reveal;
        else if (!batches[batchId].settled) phase = Phase.Settling;
        else phase = Phase.Settled;
    }

    function currentBatch() public view returns (uint256) {
        return (block.number - genesis) / commitBlocks;
    }

    function requiredDeposit() external view returns (uint256) {
        return deposit;
    }

    function forfeitBps() external view returns (uint16) {
        return forfeit;
    }

    function rationing() external pure returns (Rationing) {
        return Rationing.ProRata;
    }

    function commitmentOf(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(TYPEHASH, block.chainid, address(this), batchId, committer, order, salt));
    }

    // ============ Commit ============

    function commit(bytes32 commitment) external payable {
        uint256 batchId = currentBatch();
        if (msg.value != deposit) revert BadDeposit();
        Batch storage b = batches[batchId];
        if (b.commits >= maxCommits) revert BatchFull();
        Commitment storage c = _commitments[commitment];
        if (c.status != Status.None) revert DuplicateCommitment();
        b.commits += 1;
        c.committer = msg.sender;
        c.batchId = uint64(batchId);
        c.status = Status.Committed;
        emit Committed(batchId, msg.sender, commitment, msg.value);
    }

    // ============ Reveal ============

    function reveal(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt)
        external
        nonReentrant
    {
        (,, Phase phase) = schedule(batchId);
        if (phase != Phase.Reveal) revert WrongPhase();
        bytes32 id = commitmentOf(batchId, committer, order, salt);
        Commitment storage c = _commitments[id];
        if (c.status == Status.None) revert UnknownCommitment();
        if (c.status != Status.Committed) revert AlreadyRevealed();
        // The opening must name the account that paid the deposit; otherwise anyone could commit an order
        // in another account's name and, by revealing it, spend that account's token approval.
        if (c.committer != committer) revert NotCommitter();
        if (order.sellAmount == 0 || order.limitPrice == 0) revert BadOrder();

        c.order = order;
        bool supported = (order.sellToken == base && order.buyToken == quote)
            || (order.sellToken == quote && order.buyToken == base);
        if (!supported) {
            // Sealed orders cannot be checked at commit, so an order for another pair is opened, not
            // filled, and its deposit is returned whole.
            c.status = Status.Unsupported;
        } else {
            uint256 before = IERC20Minimal(order.sellToken).balanceOf(address(this));
            _safeTransferFrom(order.sellToken, committer, address(this), order.sellAmount);
            if (IERC20Minimal(order.sellToken).balanceOf(address(this)) - before != order.sellAmount) {
                revert EscrowShort(); // fee-on-transfer and similar tokens are refused
            }
            c.status = Status.Revealed;
            _revealed[batchId].push(id);
        }
        emit Revealed(batchId, committer, id, order);
    }

    // ============ Settle ============

    /// @dev The revealed orders of one batch, flattened for clearing. A seller sells base for quote; a buyer
    ///      sells quote for base. `key` is a seller's least acceptable price or a buyer's greatest.
    struct Book {
        bool[] isSeller;
        uint256[] amount;
        uint256[] key;
    }

    function settle(uint256 batchId) external nonReentrant {
        (, uint64 revealEnd,) = schedule(batchId);
        if (block.number <= revealEnd) revert WrongPhase();
        Batch storage b = batches[batchId];
        if (b.settled) revert AlreadySettled();
        b.settled = true;

        bytes32[] storage ids = _revealed[batchId];
        Book memory bk = _book(ids);

        (uint256 price, uint256 volume) = _clearingPrice(bk);
        if (volume == 0) return; // nothing crosses; every order is returned at claim

        (uint256 baseTarget, uint256 quoteTarget) = _targets(bk, price, volume);
        // A batch too small to move one unit of either token does not trade; sellers would otherwise give base
        // for nothing.
        if (baseTarget == 0 || quoteTarget == 0) return;
        b.price = price;

        uint256[] memory fill = new uint256[](ids.length);
        _ration(bk, price, true, baseTarget, fill);
        _ration(bk, price, false, quoteTarget, fill);
        (uint256 baseIn, uint256 quoteIn) = _record(ids, bk, price, fill);
        emit BatchCleared(batchId, base, quote, price, baseIn, quoteIn);
    }

    function _book(bytes32[] storage ids) internal view returns (Book memory bk) {
        uint256 n = ids.length;
        bk.isSeller = new bool[](n);
        bk.amount = new uint256[](n);
        bk.key = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            LimitOrder storage o = _commitments[ids[i]].order;
            bool seller = o.sellToken == base;
            bk.isSeller[i] = seller;
            bk.amount[i] = o.sellAmount;
            // A seller of base accepts p >= limitPrice. A seller of quote wants at least limitPrice base per
            // quote, which is p * limitPrice <= 1e36, so its highest acceptable p is floor(1e36 / limitPrice).
            bk.key[i] = seller ? o.limitPrice : ONE_SQUARED / o.limitPrice;
        }
    }

    /// @dev Exactly one side can be long at the clearing price. The short side fills in full; the long side
    ///      fills best limit first and shares the last level pro-rata (Rationing.ProRata). Targets are in the
    ///      token each side sells: base for sellers, quote for buyers.
    function _targets(Book memory bk, uint256 price, uint256 volume)
        internal
        pure
        returns (uint256 baseTarget, uint256 quoteTarget)
    {
        (uint256 supply, uint256 buyQuote) = _sides(bk, price);
        uint256 demand = buyQuote * ONE / price;
        if (supply > volume) {
            // sellers long: they deliver exactly the base that the buyers' quote buys
            baseTarget = volume;
            quoteTarget = buyQuote;
        } else {
            baseTarget = supply;
            // buyers long: they pay the quote the sellers' base is worth, rounded down
            quoteTarget = demand > volume ? volume * price / ONE : buyQuote;
        }
    }

    /// @dev Write each order's fill and proceeds (rounded down), and send the rounding dust to the sink.
    function _record(bytes32[] storage ids, Book memory bk, uint256 price, uint256[] memory fill)
        internal
        returns (uint256 baseIn, uint256 quoteIn)
    {
        uint256 baseOut;
        uint256 quoteOut;
        for (uint256 i = 0; i < ids.length; i++) {
            if (fill[i] == 0) continue;
            Commitment storage c = _commitments[ids[i]];
            c.sold = fill[i];
            if (bk.isSeller[i]) {
                c.bought = fill[i] * price / ONE;
                baseIn += fill[i];
                quoteOut += c.bought;
            } else {
                c.bought = fill[i] * ONE / price;
                quoteIn += fill[i];
                baseOut += c.bought;
            }
        }
        // Never negative by construction; the conservation tests check it.
        sinkTokens[base] += baseIn - baseOut;
        sinkTokens[quote] += quoteIn - quoteOut;
    }

    /// @dev Base volume at price p: min(supply, demand), with supply = sum of base offered at limits <= p and
    ///      demand = (sum of quote offered at limits >= p) / p. Supply rises and demand falls with p, so the
    ///      prices of maximum volume form one interval, and the maximum is reached at some order's limit.
    ///      The clearing price is the midpoint of the lowest and highest limits that reach the maximum.
    function _clearingPrice(Book memory bk) internal pure returns (uint256 price, uint256 volume) {
        uint256 lo;
        uint256 hi;
        for (uint256 i = 0; i < bk.key.length; i++) {
            uint256 p = bk.key[i];
            if (p == 0) continue;
            (uint256 s, uint256 q) = _sides(bk, p);
            uint256 d = q * ONE / p;
            uint256 v = s < d ? s : d;
            if (v > volume) {
                volume = v;
                lo = p;
                hi = p;
            } else if (v == volume && v > 0) {
                if (p < lo) lo = p;
                if (p > hi) hi = p;
            }
        }
        if (volume == 0) return (0, 0);
        price = (lo + hi) / 2;
    }

    /// @dev Base offered by sellers whose limit admits p, and quote offered by buyers whose limit admits p.
    function _sides(Book memory bk, uint256 p) internal pure returns (uint256 baseOffered, uint256 quoteOffered) {
        for (uint256 i = 0; i < bk.key.length; i++) {
            if (bk.isSeller[i]) {
                if (bk.key[i] <= p) baseOffered += bk.amount[i];
            } else if (bk.key[i] >= p) {
                quoteOffered += bk.amount[i];
            }
        }
    }

    /// @dev Fill one side up to `target` units of what that side sells, best limit first (lowest for sellers,
    ///      highest for buyers). Orders at the last level reached share what is left in proportion to size;
    ///      the few units lost to rounding go one each to that level's orders in index order, so the side
    ///      delivers exactly `target`.
    function _ration(Book memory bk, uint256 p, bool sellers, uint256 target, uint256[] memory fill)
        internal
        pure
    {
        uint256 n = bk.key.length;
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (_inSide(bk, i, p, sellers)) total += bk.amount[i];
        }
        if (target >= total) {
            for (uint256 i = 0; i < n; i++) {
                if (_inSide(bk, i, p, sellers)) fill[i] = bk.amount[i];
            }
            return;
        }
        if (target == 0) return;

        uint256 level = _marginalLevel(bk, p, sellers, target);
        uint256 better;
        uint256 atLevel;
        for (uint256 i = 0; i < n; i++) {
            if (!_inSide(bk, i, p, sellers)) continue;
            if (bk.key[i] == level) {
                atLevel += bk.amount[i];
            } else if (!_worse(bk.key[i], level, sellers)) {
                fill[i] = bk.amount[i];
                better += bk.amount[i];
            }
        }
        uint256 rest = target - better;
        uint256 given;
        for (uint256 i = 0; i < n; i++) {
            if (_inSide(bk, i, p, sellers) && bk.key[i] == level) {
                fill[i] = bk.amount[i] * rest / atLevel;
                given += fill[i];
            }
        }
        for (uint256 i = 0; i < n && given < rest; i++) {
            if (_inSide(bk, i, p, sellers) && bk.key[i] == level && fill[i] < bk.amount[i]) {
                fill[i] += 1;
                given += 1;
            }
        }
    }

    /// @dev The best-ranked limit on this side at which the cumulative amount (that limit and every better one)
    ///      reaches the target.
    function _marginalLevel(Book memory bk, uint256 p, bool sellers, uint256 target)
        internal
        pure
        returns (uint256 level)
    {
        bool found;
        for (uint256 i = 0; i < bk.key.length; i++) {
            if (!_inSide(bk, i, p, sellers)) continue;
            uint256 cum;
            for (uint256 j = 0; j < bk.key.length; j++) {
                if (_inSide(bk, j, p, sellers) && !_worse(bk.key[j], bk.key[i], sellers)) cum += bk.amount[j];
            }
            if (cum >= target && (!found || _worse(level, bk.key[i], sellers))) {
                level = bk.key[i];
                found = true;
            }
        }
    }

    function _inSide(Book memory bk, uint256 i, uint256 p, bool sellers) private pure returns (bool) {
        if (bk.isSeller[i] != sellers) return false;
        return sellers ? bk.key[i] <= p : bk.key[i] >= p;
    }

    /// @dev True if limit a ranks strictly worse than limit b on this side.
    function _worse(uint256 a, uint256 b, bool sellers) private pure returns (bool) {
        return sellers ? a > b : a < b;
    }

    // ============ Claim ============

    /// @notice Pay a commitment's proceeds, unfilled remainder and deposit (less any forfeit) to its committer.
    ///         Callable by anyone; the money only ever goes to the committer.
    function claim(uint256 batchId, bytes32 commitment) external nonReentrant {
        Commitment storage c = _commitments[commitment];
        if (c.status == Status.None || c.batchId != batchId || c.claimed) revert NotClaimable();
        (, uint64 revealEnd,) = schedule(batchId);
        if (block.number <= revealEnd) revert NotClaimable();
        if (c.status == Status.Revealed && !batches[batchId].settled) revert NotClaimable();
        c.claimed = true;

        uint256 refund = deposit;
        if (c.status == Status.Committed) {
            uint256 kept = deposit * forfeit / 10_000;
            refund -= kept;
            sinkEth += kept;
            emit Forfeited(batchId, commitment, kept, refund);
        } else if (c.status == Status.Revealed) {
            LimitOrder storage o = c.order;
            if (c.bought > 0) _safeTransfer(o.buyToken, c.committer, c.bought);
            if (o.sellAmount > c.sold) _safeTransfer(o.sellToken, c.committer, o.sellAmount - c.sold);
        }
        if (refund > 0) {
            (bool ok,) = c.committer.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Send accumulated forfeits and rounding dust to the sink. Callable by anyone.
    function flushSink() external nonReentrant {
        uint256 e = sinkEth;
        uint256 b = sinkTokens[base];
        uint256 q = sinkTokens[quote];
        sinkEth = 0;
        sinkTokens[base] = 0;
        sinkTokens[quote] = 0;
        if (b > 0) _safeTransfer(base, sink, b);
        if (q > 0) _safeTransfer(quote, sink, q);
        if (e > 0) {
            (bool ok,) = sink.call{value: e}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ============ Views ============

    function commitmentInfo(bytes32 commitment)
        external
        view
        returns (address committer, uint64 batchId, Status status, bool claimed, uint256 sold, uint256 bought)
    {
        Commitment storage c = _commitments[commitment];
        return (c.committer, c.batchId, c.status, c.claimed, c.sold, c.bought);
    }

    function revealedCount(uint256 batchId) external view returns (uint256) {
        return _revealed[batchId].length;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERCSealedBatchAuction).interfaceId || interfaceId == ERC5732_COMMIT_CORE
            || interfaceId == ERC165;
    }

    // ============ Token transfers ============

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

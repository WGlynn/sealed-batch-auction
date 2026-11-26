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
/// @dev Written for clarity, not gas. Settlement is O(n^2) in the orders of a batch, so commitments per batch are
///      capped (at most 64 here, which keeps settle under the 2^24 per-transaction gas cap of EIP-7825). With
///      sellAmount < 2^112, limitPrice < 2^128, at most 64 orders and priceScale <= 1e36, every product below fits
///      in 256 bits. Not audited.
contract SealedBatchAuction is IERCSealedBatchAuction {
    // ============ Constants ============

    uint256 public constant MAX_SELL_AMOUNT = 2 ** 112; // exclusive
    uint256 public constant MAX_LIMIT_PRICE = 2 ** 128; // exclusive
    uint32 public constant MAX_COMMITS_LIMIT = 64;
    /// One Ethereum epoch: a settle window this long spans many block producers, so no single producer can let a
    /// batch expire by leaving it unsettled. A day of blocks is the recommended setting.
    uint64 public constant MIN_SETTLE_BLOCKS = 32;

    bytes32 public constant TYPEHASH = keccak256(
        "SealedBatchOrder(uint256 chainId,address venue,uint256 batchId,address committer,LimitOrder order,bytes32 salt)"
        "LimitOrder(address sellToken,address buyToken,uint256 sellAmount,uint256 limitPrice)"
    );

    bytes4 private constant ERC5732_COMMIT_CORE = 0xf14fcbc8;
    bytes4 private constant ERC165 = 0x01ffc9a7;

    // ============ Configuration ============

    struct Config {
        address tokenA;
        address tokenB;
        uint64 commitBlocks;
        uint64 revealBlocks;
        uint64 settleBlocks; // how long after the reveal window a batch can be settled before it expires
        uint256 deposit;
        uint16 forfeitBps;
        uint32 maxCommits;
        uint256 priceScale; // at most 1e36
        uint16 tieToleranceBps;
        uint256 minA; // least sellAmount of an order selling tokenA
        uint256 minB; // least sellAmount of an order selling tokenB
        address sink; // receives forfeits and rounding dust; fixed at deployment
    }

    address public immutable base; // the lower token address of the pair
    address public immutable quote;
    uint64 public immutable genesis; // block at which batch 0 opens
    uint64 public immutable commitBlocks;
    uint64 public immutable revealBlocks;
    uint64 public immutable settleBlocks;
    uint256 public immutable deposit;
    uint16 public immutable forfeit;
    uint32 public immutable maxCommits;
    uint256 public immutable scale;
    uint16 public immutable tolerance;
    uint256 public immutable minBase;
    uint256 public immutable minQuote;
    address public immutable sink;

    // ============ State ============

    enum Status {
        None,
        Committed,
        Revealed, // opened, escrowed, takes part in clearing
        Invalid // opened, but cannot trade on this venue: not escrowed, forfeits like an unopened commitment
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
        uint256 price; // 0 if the batch did not trade
    }

    mapping(bytes32 => Commitment) internal _commitments;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => bytes32[]) internal _revealed;

    uint256 public sinkEth;
    mapping(address => uint256) public sinkTokens;
    /// Payments that could not be pushed (a token that blocks the recipient, a contract that rejects ether), held
    /// for the recipient to pull. address(0) is ether.
    mapping(address => mapping(address => uint256)) public owed;

    uint256 private _lock = 1;

    // ============ Errors ============

    error WrongPhase();
    error BadDeposit();
    error BatchFull();
    error DuplicateCommitment();
    error UnknownCommitment();
    error NotCommitter();
    error WrongBatch();
    error AlreadyRevealed();
    error EscrowShort();
    error AlreadySettled();
    error NotClaimable();
    error BatchOutOfRange();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(Config memory cfg) {
        require(cfg.tokenA != cfg.tokenB && cfg.tokenA != address(0) && cfg.tokenB != address(0), "pair");
        require(cfg.commitBlocks > 0 && cfg.revealBlocks >= 2 && cfg.settleBlocks >= MIN_SETTLE_BLOCKS, "windows");
        require(cfg.forfeitBps <= 10_000 && cfg.tieToleranceBps < 10_000, "bps");
        require(cfg.maxCommits > 0 && cfg.maxCommits <= MAX_COMMITS_LIMIT, "cap");
        require(cfg.priceScale > 0 && cfg.priceScale <= 1e36, "scale");
        require(cfg.sink != address(0), "sink");
        bool aIsBase = cfg.tokenA < cfg.tokenB;
        (base, quote) = aIsBase ? (cfg.tokenA, cfg.tokenB) : (cfg.tokenB, cfg.tokenA);
        (minBase, minQuote) = aIsBase ? (cfg.minA, cfg.minB) : (cfg.minB, cfg.minA);
        genesis = uint64(block.number);
        commitBlocks = cfg.commitBlocks;
        revealBlocks = cfg.revealBlocks;
        settleBlocks = cfg.settleBlocks;
        deposit = cfg.deposit;
        forfeit = cfg.forfeitBps;
        maxCommits = cfg.maxCommits;
        scale = cfg.priceScale;
        tolerance = cfg.tieToleranceBps;
        sink = cfg.sink;
    }

    // ============ Schedule ============

    /// @dev Batch k takes commitments in blocks [genesis + k*C, genesis + (k+1)*C - 1], is revealed in the R blocks
    ///      after that, and can be settled in the S blocks after that. Batches overlap: batch k is revealed while
    ///      batch k+1 takes commitments. A commitment belongs to the batch that was current when it was made.
    function schedule(uint256 batchId)
        public
        view
        returns (uint64 commitEnd, uint64 revealEnd, uint64 settleEnd, Phase phase)
    {
        if (batchId >= type(uint64).max) revert BatchOutOfRange();
        uint256 ce = uint256(genesis) + (batchId + 1) * commitBlocks - 1;
        uint256 se = ce + revealBlocks + settleBlocks;
        if (se > type(uint64).max) revert BatchOutOfRange();
        commitEnd = uint64(ce);
        revealEnd = uint64(ce + revealBlocks);
        settleEnd = uint64(se);
        if (block.number <= commitEnd) phase = Phase.Commit;
        else if (block.number <= revealEnd) phase = Phase.Reveal;
        else if (batches[batchId].settled) phase = Phase.Settled;
        else if (block.number <= settleEnd) phase = Phase.Settling;
        else phase = Phase.Expired;
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

    function priceScale() external view returns (uint256) {
        return scale;
    }

    function tieToleranceBps() external view returns (uint16) {
        return tolerance;
    }

    function maxCommitments() external view returns (uint32) {
        return maxCommits;
    }

    function minSellAmount(address token) public view returns (uint256) {
        if (token == base) return minBase;
        if (token == quote) return minQuote;
        return type(uint256).max; // not traded here
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
        (,,, Phase phase) = schedule(batchId);
        if (phase != Phase.Reveal) revert WrongPhase();
        bytes32 id = commitmentOf(batchId, committer, order, salt);
        Commitment storage c = _commitments[id];
        if (c.status == Status.None) revert UnknownCommitment();
        if (c.status != Status.Committed) revert AlreadyRevealed();
        // A commitment opens only into the batch it was made in. Batches overlap, so without this check an order
        // committed after a batch's reveals were public could be opened into that batch.
        if (c.batchId != batchId) revert WrongBatch();
        // The opening must name the account that paid the deposit; otherwise anyone could commit an order in
        // another account's name and, by revealing it, spend that account's token approval.
        if (c.committer != committer) revert NotCommitter();

        c.order = order;
        // A limit at or above the bound means "any price"; clamp it rather than reject a market order.
        if (order.limitPrice >= MAX_LIMIT_PRICE) c.order.limitPrice = MAX_LIMIT_PRICE - 1;
        if (!_tradable(order)) {
            // The venue's pairs, minimums and bounds are public, so an order that cannot trade is the committer's
            // error. It forfeits like an unopened commitment; otherwise the commitment cap could be filled for free.
            c.status = Status.Invalid;
            return;
        }
        uint256 before = IERC20Minimal(order.sellToken).balanceOf(address(this));
        _pull(order.sellToken, committer, order.sellAmount);
        if (IERC20Minimal(order.sellToken).balanceOf(address(this)) - before != order.sellAmount) {
            revert EscrowShort(); // fee-on-transfer and similar tokens are refused
        }
        c.status = Status.Revealed;
        _revealed[batchId].push(id);
        emit Revealed(batchId, committer, id, order);
    }

    function _tradable(LimitOrder calldata o) internal view returns (bool) {
        bool pair = (o.sellToken == base && o.buyToken == quote) || (o.sellToken == quote && o.buyToken == base);
        return pair && o.sellAmount > 0 && o.sellAmount >= minSellAmount(o.sellToken)
            && o.sellAmount < MAX_SELL_AMOUNT && o.limitPrice > 0;
    }

    // ============ Settle ============

    /// @dev The revealed orders of one batch, flattened for clearing. A seller sells base for quote; a buyer sells
    ///      quote for base. `key` is the order's limit in the pair's price unit: a seller's least price, a buyer's
    ///      greatest.
    struct Book {
        bool[] isSeller;
        uint256[] amount;
        uint256[] key;
    }

    function settle(uint256 batchId) external nonReentrant {
        (,,, Phase phase) = schedule(batchId);
        if (phase == Phase.Settled) revert AlreadySettled();
        if (phase != Phase.Settling) revert WrongPhase();
        _settle(batchId);
    }

    function _settle(uint256 batchId) internal {
        Batch storage b = batches[batchId];
        b.settled = true;

        bytes32[] storage ids = _revealed[batchId];
        Book memory bk = _book(ids);

        uint256 price = _clearingPrice(bk);
        if (price == 0) return; // nothing crosses; every order is returned at claim

        (uint256 baseTarget, uint256 quoteTarget) = _targets(bk, price);
        // A batch too small to move one unit of either token does not trade.
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
            bk.isSeller[i] = o.sellToken == base;
            bk.amount[i] = o.sellAmount;
            bk.key[i] = o.limitPrice;
        }
    }

    /// @dev Base volume at price p: V(p) = min(S(p), D(p)), where S(p) is the base offered at limits <= p and
    ///      D(p) = floor(Q(p) * scale / p), Q(p) being the quote offered at limits >= p. Among the distinct order
    ///      limits, take Vmax, then the limits whose volume is within `tolerance` of it; the clearing price is the
    ///      floor of the midpoint of the lowest and highest of those. S rises and D falls with p, so every price
    ///      between those two limits also has volume within the tolerance.
    function _clearingPrice(Book memory bk) internal view returns (uint256 price) {
        uint256 vmax;
        for (uint256 i = 0; i < bk.key.length; i++) {
            uint256 v = _volume(bk, bk.key[i]);
            if (v > vmax) vmax = v;
        }
        if (vmax == 0) return 0;
        uint256 threshold = vmax - vmax * tolerance / 10_000;
        uint256 lo = type(uint256).max;
        uint256 hi;
        for (uint256 i = 0; i < bk.key.length; i++) {
            uint256 p = bk.key[i];
            if (_volume(bk, p) >= threshold) {
                if (p < lo) lo = p;
                if (p > hi) hi = p;
            }
        }
        price = (lo + hi) / 2;
    }

    function _volume(Book memory bk, uint256 p) internal view returns (uint256) {
        (uint256 s, uint256 q) = _sides(bk, p);
        uint256 d = q * scale / p;
        return s < d ? s : d;
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

    /// @dev At the clearing price at most one side is long. The short side fills in full; the long side fills best
    ///      limit first and shares the last level pro-rata. Targets are in the token each side sells.
    function _targets(Book memory bk, uint256 price) internal view returns (uint256 baseTarget, uint256 quoteTarget) {
        (uint256 supply, uint256 buyQuote) = _sides(bk, price);
        uint256 demand = buyQuote * scale / price;
        uint256 volume = supply < demand ? supply : demand;
        if (supply > volume) {
            // sellers long: they deliver exactly the base that the buyers' quote buys
            baseTarget = volume;
            quoteTarget = buyQuote;
        } else {
            baseTarget = supply;
            // buyers long: they pay the quote the sellers' base is worth, rounded down
            quoteTarget = demand > volume ? volume * price / scale : buyQuote;
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
                c.bought = fill[i] * price / scale;
                baseIn += fill[i];
                quoteOut += c.bought;
            } else {
                c.bought = fill[i] * scale / price;
                quoteIn += fill[i];
                baseOut += c.bought;
            }
        }
        // Never negative by construction; the conservation tests check it.
        sinkTokens[base] += baseIn - baseOut;
        sinkTokens[quote] += quoteIn - quoteOut;
    }

    /// @dev Fill one side up to `target` units of what that side sells, best limit first (lowest for sellers,
    ///      highest for buyers). Orders at the last level reached share what is left in proportion to size; the few
    ///      units lost to rounding go one each to that level's orders in reveal order, so the side delivers exactly
    ///      `target`.
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
    ///         Callable by anyone once the batch's reveal window has closed; money only ever goes to the committer.
    ///         Claiming an escrowed order in an unsettled batch settles the batch first; after the settle window,
    ///         an unsettled batch has expired and its escrow returns in full.
    function claim(uint256 batchId, bytes32 commitment) external nonReentrant {
        Commitment storage c = _commitments[commitment];
        if (c.status == Status.None || c.batchId != batchId || c.claimed) revert NotClaimable();
        (,,, Phase phase) = schedule(batchId);
        if (phase == Phase.Commit || phase == Phase.Reveal) revert NotClaimable();
        // The first claim on an escrowed order settles the batch if nobody has yet, so a trader never has to wait
        // for, or depend on, a separate settle transaction.
        if (c.status == Status.Revealed && phase == Phase.Settling) _settle(batchId);
        c.claimed = true;

        address to = c.committer;
        uint256 refund = deposit;
        if (c.status == Status.Committed || c.status == Status.Invalid) {
            uint256 kept = deposit * forfeit / 10_000;
            refund -= kept;
            sinkEth += kept;
            emit Forfeited(batchId, commitment, kept, refund);
        } else {
            LimitOrder storage o = c.order;
            // An expired batch never settled, so sold and bought are zero and the escrow returns whole.
            if (c.bought > 0) _payOrCredit(o.buyToken, to, c.bought);
            if (o.sellAmount > c.sold) _payOrCredit(o.sellToken, to, o.sellAmount - c.sold);
        }
        if (refund > 0) _payOrCredit(address(0), to, refund);
    }

    /// @notice Pull a payment that could not be pushed at claim time. `asset` is a token, or address(0) for ether.
    function withdrawOwed(address asset) external nonReentrant {
        uint256 amount = owed[asset][msg.sender];
        owed[asset][msg.sender] = 0;
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else if (!_push(asset, msg.sender, amount)) {
            revert TransferFailed();
        }
    }

    /// @notice Send accumulated forfeits (ether) or rounding dust (a token) to the sink. Callable by anyone, one
    ///         asset at a time, so one failing asset cannot hold up the others.
    function flushSink(address asset) external nonReentrant {
        if (asset == address(0)) {
            uint256 e = sinkEth;
            sinkEth = 0;
            (bool ok,) = sink.call{value: e}("");
            if (!ok) revert TransferFailed();
        } else {
            uint256 t = sinkTokens[asset];
            sinkTokens[asset] = 0;
            if (t > 0 && !_push(asset, sink, t)) revert TransferFailed();
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

    // ============ Transfers ============

    function _payOrCredit(address asset, address to, uint256 amount) private {
        bool ok;
        if (asset == address(0)) {
            (ok,) = to.call{value: amount}("");
        } else {
            ok = _push(asset, to, amount);
        }
        if (!ok) owed[asset][to] += amount;
    }

    function _push(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        return ok && (data.length == 0 ? token.code.length > 0 : abi.decode(data, (bool)));
    }

    function _pull(address token, address from, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, address(this), amount)));
        if (!ok || (data.length == 0 ? token.code.length == 0 : !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

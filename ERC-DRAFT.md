---
eip: TBD
title: Sealed-Bid Batch Auction
description: Commit-reveal batch auctions that settle every filled order at one uniform clearing price.
author: Will Glynn (@WGlynn)
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-11-25
requires: 165, 5732
---

## Abstract

This ERC defines an interface for exchange venues that collect sealed orders over a fixed window, reveal them
together, and settle each token pair at a single clearing price. Orders are committed as hashes through
[ERC-5732](https://eips.ethereum.org/EIPS/eip-5732), opened in a reveal window measured in blocks, and settled by anyone once the window
closes. Every filled order in a batch gets the same price, so there is no position inside the batch to buy or to
front-run. The interface fixes the commitment format, the phase schedule, the clearing rules down to the rounding,
the penalty for not revealing, and the events that report each batch.

## Motivation

On a continuous exchange the order in which transactions land decides who gets which price. Whoever controls or
buys that order (a builder, a searcher, a fast trader) can trade ahead of others. Sealed batch auctions remove the
prize: nobody sees an order before the window closes, and everyone in the batch gets the same price, so position
in the batch is worth nothing.

Batch auctions with one clearing price already run in production, each with its own interface. CoW Protocol has
solvers compute batch prices off chain and settle through allow-listed contracts; Angstrom has a staked node
network clear each block's orders, after a top-of-block arbitrage slot, at one price per pair; Injective clears its
order book in a batch at the end of each block. None of them seals orders on chain, so a wallet or aggregator
integrates each one separately and an indexer cannot read batch prices in one way.

Existing standards cover parts of this. ERC-5732 standardizes a bare `commit(bytes32)` and leaves the reveal open.
A draft fractional batch auction token standard defines a batch double auction for real-world-asset shares, with
orders posted in the clear and a clearing price computed off chain and submitted through a function whose caller
that text neither restricts nor verifies. A draft sealed-bid award standard for task tenders defines a bonded
commit-reveal with permissionless finalization, for one-sided procurement of a task rather than two-sided trade
between tokens. None of them defines a sealed, permissionlessly settled batch for token pairs.

A shared interface lets wallets commit and reveal to any compliant venue with one code path, lets relayers reveal
on a user's behalf so that a user who goes offline, or is censored for a block, still has the order opened, and
gives indexers and oracles one `BatchCleared` event across venues. Because the clearing rules run on chain and
anyone can settle, a wallet can route an order to any compliant venue without trusting its operator to set the
price.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT
RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Interface

```solidity
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

enum Phase { Commit, Reveal, Settling, Settled, Expired }
enum Rationing { ProRata, SeededOrder }

/// A compliant venue also implements ERC-5732's IERC_COMMIT_CORE and ERC-165.
interface IERCSealedBatchAuction {
    event Committed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, uint256 deposit);
    event Revealed(uint256 indexed batchId, address indexed committer, bytes32 indexed commitment, LimitOrder order);
    event Forfeited(uint256 indexed batchId, bytes32 indexed commitment, uint256 forfeited, uint256 refunded);
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
        external view returns (uint64 commitEnd, uint64 revealEnd, uint64 settleEnd, Phase phase);
    function requiredDeposit() external view returns (uint256);
    function forfeitBps() external view returns (uint16);
    function rationing() external view returns (Rationing);
    function priceScale() external view returns (uint256);
    function tieToleranceBps() external view returns (uint16);
    function maxCommitments() external view returns (uint32);
    function minSellAmount(address token) external view returns (uint256);
    function commitmentOf(uint256 batchId, address committer, LimitOrder calldata order, bytes32 salt)
        external view returns (bytes32);
}
```

### Pairs, prices and orders

1. For a pair of tokens, the **base** is the token with the lower address and the **quote** is the other. Prices are
   quote units per base unit, multiplied by `priceScale()`, a constant the venue declares. Volumes are in base.
   A venue SHOULD choose a scale that gives its pair enough precision; a token worth far less than its quote needs
   a larger scale than 1e18.
2. An order selling base accepts a price `p` if `p >= limitPrice`. An order selling quote accepts `p` if
   `p <= limitPrice`.
3. A `limitPrice` at or above `2^128` MUST be treated as `2^128 - 1`, so an order that accepts any price is valid.
   An order is **tradable** on a venue if it is for a pair the venue trades, `sellAmount >= minSellAmount(sellToken)`,
   `0 < sellAmount < 2^112` and `limitPrice > 0`. An opened order that is not tradable MUST NOT be escrowed or
   filled, and forfeits like an unopened commitment (rule 13). The venue's pairs, minimums and every other parameter
   MUST stay fixed from the start of a batch's commit window to the end of its settle window, so an order that was
   tradable when committed stays tradable. The bounds keep every product in rules 14 to 16 within 256 bits for
   scales up to 1e36 and caps up to 64 orders.

### Commitments

4. A commitment MUST be
   `keccak256(abi.encode(TYPEHASH, block.chainid, address(this), batchId, committer, order, salt))`, where
   `TYPEHASH = keccak256("SealedBatchOrder(uint256 chainId,address venue,uint256 batchId,address committer,LimitOrder order,bytes32 salt)LimitOrder(address sellToken,address buyToken,uint256 sellAmount,uint256 limitPrice)")`.
   `TYPEHASH` is a domain tag only: the order is encoded inline, so this is not an [EIP-712](https://eips.ethereum.org/EIPS/eip-712) struct hash and EIP-712
   libraries will not reproduce it.
5. `commitmentOf` MUST return the same value, so wallets can check their encoding.
6. `commit` MUST record `msg.sender` as the committer and `currentBatch()` as the commitment's batch. It MUST revert
   if `msg.value != requiredDeposit()`, if the commitment already exists, or if the batch already holds
   `maxCommitments()` commitments.
7. `requiredDeposit()` MUST NOT depend on the order. A deposit that scales with order size reveals the size before
   the reveal.

### Schedule

8. Batch `k` takes commitments while `block.number <= commitEnd(k)`, is revealed while
   `commitEnd(k) < block.number <= revealEnd(k)`, can be settled while `revealEnd(k) < block.number <= settleEnd(k)`,
   and is Expired after that unless it was settled. `schedule` reports the three bounds and the phase.
   `currentBatch()` is the batch taking commitments. Batches MAY overlap: batch `k + 1` can take commitments while
   batch `k` is revealed. `schedule` MUST revert for a `batchId` whose bounds do not fit in `uint64`.
9. The reveal window (`revealEnd - commitEnd`) MUST be at least 2 blocks. The settle window (`settleEnd - revealEnd`)
   MUST be at least 32 blocks, so that it spans many block producers; about a day of blocks is RECOMMENDED.

### Reveals

10. `reveal` MUST revert outside the batch's reveal window, if no commitment matches the opening, if the matching
    commitment was already opened, **if the commitment was made in a batch other than `batchId`**, or if the
    opening's `committer` is not the committer recorded at commit. The batch check matters because batches overlap:
    without it, an order committed after a batch's reveals are public could be opened into that batch. The
    committer check matters because anyone may reveal: without it, anyone could commit an order in another
    account's name and spend that account's token approval by revealing it.
11. An opening that matches no commitment reverts and is not penalized, since anyone can call `reveal`.
12. For a tradable order the venue MUST take `sellAmount` of `sellToken` from the committer into escrow, and MUST
    revert if it receives less. Escrow at reveal keeps the token and size hidden until then. If escrow fails the
    reveal reverts, and the commitment forfeits unless it is opened later in the window.
13. A commitment that is unopened at `revealEnd`, or that opened an order that is not tradable, forfeits
    `floor(deposit * forfeitBps() / 10000)` of its deposit, taken when the commitment is claimed. Forfeited funds MUST
    go to a recipient fixed when the venue is deployed. A burn address or a party with no stake in the venue's
    batches is RECOMMENDED.

### Clearing

For each traded pair with tradable revealed orders on both sides, `settle` computes one price `p*`. Let `S(p)` be the
base offered by orders selling base that accept `p`, `Q(p)` the quote offered by orders selling quote that accept
`p`, `D(p) = floor(Q(p) * priceScale() / p)`, and `V(p) = min(S(p), D(p))`.

14. Let `L` be the set of distinct `limitPrice` values of the batch's tradable orders on the pair, and
    `Vmax = max { V(p) : p in L }`. If `Vmax = 0` the pair does not trade. Otherwise let
    `N = { p in L : V(p) >= Vmax - floor(Vmax * tieToleranceBps() / 10000) }`, and
    `p* = floor((min N + max N) / 2)`. `S` rises and `D` falls with `p`, so every price between `min N` and `max N`
    has volume within the tolerance, `p*` included. A `tieToleranceBps()` above zero is RECOMMENDED: at zero, an
    order of one unit can make its own limit the unique maximum and move `p*` anywhere in the spread. The tolerance
    stops only orders smaller than about `tieToleranceBps` of the batch's volume; Security Considerations gives the
    numbers for larger ones.
15. Every fill MUST be at `p*`. An order selling base that delivers `f` base receives `floor(f * p* / priceScale())`
    quote; an order selling quote that delivers `f` quote receives `floor(f * priceScale() / p*)` base. An order MUST
    NOT be filled unless it accepts `p*`. A fee, if any, MUST be one rate for every order in the batch.
16. Let `V* = V(p*)`. If `S(p*) > V*`, orders selling base deliver `V*` base in total and orders selling quote deliver
    `Q(p*)`. Otherwise orders selling base deliver `S(p*)`, and orders selling quote deliver
    `floor(V* * p* / priceScale())` if `D(p*) > V*`, or `Q(p*)` if not. A side whose total is less than what its
    accepting orders offer is rationed: orders fill best limit first (lowest for orders selling base, highest for
    orders selling quote), and only the orders at the last limit level reached share the rest. With `ProRata`, each
    such order delivers `floor(amount * rest / levelTotal)`, and the units this leaves over go one each to those
    orders in reveal order. With `SeededOrder`, the venue documents the seed and the order it draws. `ProRata` is
    RECOMMENDED because it needs no randomness.
17. Total base received by orders selling quote MUST NOT exceed total base delivered by orders selling base, and
    likewise for quote. The difference is rounding dust and goes to the recipient of rule 13.
18. A pair whose totals under rule 16 would be zero on either side MUST NOT trade.
19. A venue MAY add a liquidity source, such as an automated market maker's curve, as one more participant with a
    known supply schedule. It MUST then document the price set it searches in place of `L` in rule 14, and the
    source is bound by rules 15 to 17 like any order.
20. `settle` MUST emit one `BatchCleared` per pair that traded, with `p*` and, as volumes, the base and quote
    delivered by the orders selling each.
21. `settle` MUST revert unless the batch is in its settle window and not yet settled. The first `claim` on an
    escrowed order of an unsettled batch in its settle window MUST settle the batch first, so no trader depends on
    a separate settle transaction.

### Claims, events and interfaces

22. `claim` MUST revert while `block.number <= revealEnd` and for a commitment already claimed, and `reveal` MUST
    revert for a claimed commitment. `claim` MAY be called by anyone and MUST pay only the commitment's committer.
    For a commitment that forfeits (rule 13) it pays the deposit less the forfeit. For an escrowed order it pays the
    proceeds, the unfilled part of `sellAmount` and the full deposit once the batch is settled (rule 21), or the
    whole escrow and the full deposit if the batch expired unsettled.
23. A payment that cannot be delivered (a recipient that rejects ether, a token that blocks it) SHOULD be held for
    the recipient to withdraw rather than revert the whole claim.
24. `commit` MUST emit `Committed`. A reveal that escrows an order MUST emit `Revealed`; an opening of an order that
    is not tradable MUST NOT. Every forfeit MUST emit `Forfeited`.
25. `supportsInterface` MUST return true for this interface's ID (`0x2c638b2a`), for ERC-5732's `IERC_COMMIT_CORE` (`0xf14fcbc8`)
    and for [ERC-165](https://eips.ethereum.org/EIPS/eip-165) (`0x01ffc9a7`).
26. `maxCommitments()` MUST be small enough that `settle` with that many orders fits the chain's per-transaction gas
    limit (16,777,216 on Ethereum since [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825)). Since rule 10 confines each commitment to its
    batch, a batch never holds more revealed orders than commitments.

## Rationale

**Why sealed and uniform.** A sealed order cannot be traded against before the window closes, and a uniform price
makes position in the batch worthless, which removes the incentive to reorder. This follows the frequent batch
auction proposal of Budish, Cramton and Shim, uniform-price double auctions run at short fixed intervals, with
pro-rata rationing at the margin[^1]. Volume maximization is also the first rule of equity exchanges' opening and
closing crosses, which then minimize the order imbalance and fill the marginal level by time priority; a sealed
batch has no time priority to use, so pro-rata takes its place. The mechanism is old; what is new is a shared
on-chain interface for it.

**Why build on ERC-5732.** It is Final and already standardizes the commit call; this ERC adds the reveal, the
schedule and the clearing rules it left open.

**Why the rounding is normative.** Two compliant venues given the same book must produce the same price and the same
fills, or indexers and routers cannot compare them. A one-unit difference in `D(p)` can change which limits are in
`N`, so every division in rules 14 to 16 is fixed.

**Why a tolerance in the tie rule.** With integer volumes the set of maximizing prices is almost always a single
point, so an exact rule hands the price to whoever adds the smallest order at the right limit. A band measured
relative to the maximum raises the size needed to do that to about `tieToleranceBps` of the batch. It does not make
it costly: Security Considerations shows the order that moves the price fills at the price its owner chose.

**Why one base token and a declared scale.** Volume in one token and volume in the other are maximized at different
prices, so the unit has to be fixed; the lower address is a choice every venue makes the same way. A single fixed
scale cannot serve both a token worth a millionth of its quote and one worth a million times it, so the venue
declares the scale its pair needs.

**Why buyer limits in the pair's price.** Expressing every limit in quote per base removes a conversion and its
rounding, and lets two orders at the same price be recognized as the same level.

**Why blocks, not seconds.** The phase boundary must be decided by the chain.

**Why reveal by anyone, and why the two checks in rule 10.** The penalty for not revealing is fair only if the
committer could always reveal; letting any holder of the opening reveal means a wallet can hand it to a relayer.
Opening the door to anyone is what makes the committer check necessary, and overlapping batches are what make the
batch check necessary.

**Why a flat deposit.** Collateral proportional to order size, taken at commit, would tell everyone the size of the
order before it is revealed, which is most of what sealing is meant to hide.

**Why untradable orders forfeit.** A refund would make every slot of a batch free to occupy.

**Why a settle window.** Settlement is permissionless but not guaranteed to happen. Without a deadline, a batch that
nobody settles, or that cannot be settled, would hold its escrow forever.

**Why price priority.** An order with a more generous limit never fills a smaller share of itself than one with a
tighter limit, while everyone pays `p*`. A generous limit is not free: it accepts any `p*` up to that limit.

## Backwards Compatibility

This ERC adds an interface and changes no existing standard. A compliant venue implements ERC-5732's
`IERC_COMMIT_CORE`. Fee-on-transfer tokens are refused at escrow (rule 12). Rebasing tokens cannot be detected at
escrow: a balance that falls between reveal and claim would leave the venue short, so venues MUST NOT list them.

## Test Cases

With `priceScale() = 1e18`, `tieToleranceBps() = 10` and amounts in units of 1e18:

| Batch | Result |
| --- | --- |
| Sell 10 base at limit 1.0; sell 20 quote at limit 2.0 | `p* = 1.5e18`; the base seller receives 15 quote; the quote seller receives 10 base and gets 5 quote back |
| The same, plus sell 1 unit (1e-18) of base at limit 1.99 | `p* = 1.5e18` (with `tieToleranceBps() = 0`, `p* = 1.99e18`) |
| Sell 6 base at 0.5, 8 at 0.9, 8 at 0.9; sell 9 quote at 0.9 | `p* = 0.9e18`; the base sellers deliver 6, 2 and 2; the quote seller receives 10 base |
| Sell 1 base at 2.0; sell 1 quote at 1.0 | no trade; every order returned at claim |

The [reference implementation's tests](test/SealedBatchAuction.t.sol) cover these and also: the
commitment's binding to chain, venue, batch and committer; overlapping batches, expiry and out-of-range batch ids;
deposit and cap checks; reveal by a relayer; a late commitment that tries to open into an earlier batch; an
opening for another batch; an order revealed in another account's name; wrong openings; fee-on-transfer refusal;
untradable and below-minimum orders; clamped market limits; forfeits; settlement by the first claim; expiry
refunds; settle gas at the cap under the EIP-7825 limit; the rule-3 bounds at a price scale of 1e36 with 64 orders;
all four events; committers that reject ether and tokens that block a recipient; and two fuzz tests (512 runs each,
2 to 12 random orders, with and without tolerance). One checks conservation of every token, the uniform price,
limits and bounded rounding dust; the other checks the exact rule-14 price against an independent model, with about
one commitment in five left unopened, and conservation of every wei of deposit.

## Reference Implementation

The [reference implementation](src/SealedBatchAuction.sol) implements this ERC for one token pair
per venue, with pro-rata rationing and no fee. It is written for clarity, not gas: settlement is O(n^2) in the
orders of a batch, about 6.7M gas at its cap of 64 commitments. It is not audited.

An earlier implementation of the same mechanism, VibeSwap's `CommitRevealAuction.sol`, predates this text and
differs from it: its commitment does not bind chain, venue or batch; its collateral is a share of the declared trade
size taken at commit; its phases are in seconds; it orders execution by a seeded shuffle; and only the committer can
reveal.

**AI assistance.** This proposal was written with AI assistance. The author worked with Jarvis, a research agent built on Claude Opus
5.5 (Anthropic) running in Claude Code, which did most of the prior-art search, the drafting of this text, the
reference implementation and its tests, and two rounds of adversarial review by separate Claude Opus 5.5 agents.
The author set the direction, made the design decisions, and reviewed and approved the text and code.

## Security Considerations

**The free option.** The reveal window is public: a committer sees earlier reveals and outside prices move, and can
choose not to reveal when the trade has turned against them, paying the forfeit. Heimbach and Wattenhofer note both
this and the cost of the delay: a commit-reveal exchange lags outside prices by a few blocks[^3]. The option is
worth more on a larger order and a flat deposit cannot see the size, so venues SHOULD bound the size of one order
(through the token's units, or a venue limit) and size the deposit to that bound. Venues SHOULD keep the reveal
window short.

**Setting the price at the margin (the main open problem).** Reveals are public as they land, so the last committer
to reveal can choose an order with the rest of the book in view. With one seller of 10 base at 1.0 and one quote
seller of 20 quote at 2.0, the clearing price is 1.5. At `tieToleranceBps() = 10`, a further sell of 0.011 base
(0.11% of the volume) at 1.9 makes 1.9 the only limit within the band, so `p* = 1.9`; it takes 0.11 base at 100
bps, and 1.2 base at 1.75 at 1000 bps. The size needed is about `V * tol / (1 - tol)`, and it is not a cost: that
order fills at the price its owner set. From the other side, one account selling and buying 0.02 base at 1.05
moves `p*` to 1.05, and the honest seller receives 10.5 quote instead of 15; rationing does not punish this,
because the account's buy fills against its own sell first. Two directions could close this, and this draft
adopts neither yet: hiding reveals until `revealEnd` (time-lock or threshold encryption), so no committer sees the
book before choosing; or a clearing rule in which no order's own limit can set the price it trades at, as in
McAfee's dominant-strategy double auction[^4], which is defined for unit orders and would need extending to
divisible ones. Comments on either are the main thing this draft asks for.

**Censorship of reveals.** A block producer who excludes a reveal makes its committer forfeit. Reveal by anyone
(rule 10), a reveal window of at least 2 blocks (rule 9) and, where available, inclusion lists reduce this. Running
the reveal over several blocks, each with a different producer, is the remedy Fox, Pai and Resnick propose for
censorship of on-chain auctions[^2]. A venue SHOULD NOT set `forfeitBps()` so high that one censored block is
ruinous.

**Filling the cap.** Untradable orders forfeit (rule 3), but tradable orders that never cross are refunded, so with a
small `minSellAmount()` an attacker can occupy every slot of a batch for the cost of gas and one batch of escrow.
Once slots are contested, the block producer decides who gets the last ones, which brings back some of the ordering
value this ERC removes elsewhere. Venues SHOULD set `minSellAmount()` high enough to make this expensive and
`maxCommitments()` as high as rule 26 allows; whether the standard needs a small non-refundable fee per commitment
is open.

**Leaving a batch unsettled.** If a batch expires, every escrow returns in full, which would be a free way out of a
trade for anyone who could keep it unsettled after seeing `p*`. The first claim settles the batch (rule 21) and the
settle window spans at least 32 blocks (rule 9), so doing this means censoring every settle and claim for the whole
window.

**Seed bias.** With `SeededOrder`, a block hash or `prevrandao` from the block that ends the reveal window can be
biased by that block's producer, who may also trade in the batch. Use pro-rata, or a seed from a block not yet
produced when the last reveal can land, and document the residual bias.

**Gas.** A cheaper settle path proposed for review: the settler passes the orders' indices sorted by limit; the venue
checks the sort in one pass, builds cumulative supply and demand in one pass, and checks rules 14 to 17 in O(n), so
the cap could rise. The settler is trusted for nothing, since a wrong sort fails the check. Gnosis Protocol v1 let
anyone submit a batch solution that its contract checked on chain; it checked that a solution improved on the
current one, where this path would check the clearing rules outright.

**Block numbers on rollups.** On chains where `block.number` follows another chain's blocks loosely, a window of a
few blocks may pass between two of the chain's own blocks. Venues on such chains SHOULD size windows for it.

**Escrow and approvals.** An approval revoked between commit and reveal makes the reveal revert (rule 12), and the
commitment forfeits if it stays unopened. Wallets SHOULD set the approval before committing.

[^1]:

    ```csl-json
    {
      "type": "article-journal",
      "id": 1,
      "author": [
        { "family": "Budish", "given": "Eric" },
        { "family": "Cramton", "given": "Peter" },
        { "family": "Shim", "given": "John" }
      ],
      "DOI": "10.1093/qje/qjv027",
      "title": "The High-Frequency Trading Arms Race: Frequent Batch Auctions as a Market Design Response",
      "container-title": "The Quarterly Journal of Economics",
      "volume": "130",
      "issue": "4",
      "page": "1547-1621",
      "original-date": { "date-parts": [[2015, 11]] },
      "URL": "https://doi.org/10.1093/qje/qjv027"
    }
    ```

[^2]:

    ```csl-json
    {
      "type": "article",
      "id": 2,
      "author": [
        { "family": "Fox", "given": "Elijah" },
        { "family": "Pai", "given": "Mallesh" },
        { "family": "Resnick", "given": "Max" }
      ],
      "DOI": "10.48550/arXiv.2301.13321",
      "title": "Censorship Resistance in On-Chain Auctions",
      "original-date": { "date-parts": [[2023, 1, 30]] },
      "URL": "https://doi.org/10.48550/arXiv.2301.13321"
    }
    ```

[^3]:

    ```csl-json
    {
      "type": "article",
      "id": 3,
      "author": [
        { "family": "Heimbach", "given": "Lioba" },
        { "family": "Wattenhofer", "given": "Roger" }
      ],
      "DOI": "10.48550/arXiv.2203.11520",
      "title": "SoK: Preventing Transaction Reordering Manipulations in Decentralized Finance",
      "original-date": { "date-parts": [[2022, 3, 22]] },
      "URL": "https://doi.org/10.48550/arXiv.2203.11520"
    }
    ```

[^4]:

    ```csl-json
    {
      "type": "article-journal",
      "id": 4,
      "author": [
        { "family": "McAfee", "given": "R. Preston" }
      ],
      "DOI": "10.1016/0022-0531(92)90091-U",
      "title": "A dominant strategy double auction",
      "container-title": "Journal of Economic Theory",
      "volume": "56",
      "issue": "2",
      "page": "434-450",
      "original-date": { "date-parts": [[1992, 4]] },
      "URL": "https://doi.org/10.1016/0022-0531(92)90091-U"
    }
    ```

## Copyright

Copyright and related rights waived via [CC0](LICENSE.md).

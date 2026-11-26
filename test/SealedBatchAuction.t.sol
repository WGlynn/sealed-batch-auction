// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SealedBatchAuction} from "../src/SealedBatchAuction.sol";
import {IERCSealedBatchAuction, LimitOrder, Phase} from "../src/IERCSealedBatchAuction.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public feeBps; // a fee-on-transfer token when nonzero
    mapping(address => bool) public blocked; // a token that refuses some recipients

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(!blocked[to], "blocked");
        require(balanceOf[from] >= amount, "balance");
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// A committer that can refuse ether, to test that a claim does not get stuck.
contract PickyReceiver {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    function commit(SealedBatchAuction v, bytes32 id) external payable {
        v.commit{value: msg.value}(id);
    }

    function approve(MockERC20 t, address spender) external {
        t.approve(spender, type(uint256).max);
    }

    function withdraw(SealedBatchAuction v, address asset) external {
        v.withdrawOwed(asset);
    }

    receive() external payable {
        require(accept, "no thanks");
    }
}

contract SealedBatchAuctionTest is Test {
    uint256 constant S = 1e18; // price scale used in these tests
    uint256 constant DEPOSIT = 0.01 ether;
    uint64 constant C = 5;
    uint64 constant R = 3;
    uint64 constant W = 10; // settle window

    SealedBatchAuction venue;
    MockERC20 base;
    MockERC20 quote;
    address sink = address(0x5111C);

    function setUp() public {
        (base, quote) = _tokens();
        venue = _venue(10, 1, 32); // 10 bps tie tolerance, minimum size 1, cap 32
    }

    // ============ Helpers ============

    function _tokens() internal returns (MockERC20 b, MockERC20 q) {
        MockERC20 x = new MockERC20();
        MockERC20 y = new MockERC20();
        (b, q) = address(x) < address(y) ? (x, y) : (y, x);
    }

    function _venue(uint16 tol, uint256 minSize, uint32 cap) internal returns (SealedBatchAuction) {
        return new SealedBatchAuction(
            SealedBatchAuction.Config({
                tokenA: address(base),
                tokenB: address(quote),
                commitBlocks: C,
                revealBlocks: R,
                settleBlocks: W,
                deposit: DEPOSIT,
                forfeitBps: 5000,
                maxCommits: cap,
                priceScale: S,
                tieToleranceBps: tol,
                minA: minSize,
                minB: minSize,
                sink: sink
            })
        );
    }

    function _trader(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// Sells `amount` base, wants at least `limit` quote per base.
    function _sell(uint256 amount, uint256 limit) internal view returns (LimitOrder memory) {
        return LimitOrder(address(base), address(quote), amount, limit);
    }

    /// Sells `amount` quote for base, pays at most `limit` quote per base.
    function _buy(uint256 amount, uint256 limit) internal view returns (LimitOrder memory) {
        return LimitOrder(address(quote), address(base), amount, limit);
    }

    function _commitOn(SealedBatchAuction v, address who, LimitOrder memory o, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        id = v.commitmentOf(v.currentBatch(), who, o, salt);
        if (o.sellToken == address(base) || o.sellToken == address(quote)) {
            MockERC20(o.sellToken).mint(who, o.sellAmount);
            vm.prank(who);
            MockERC20(o.sellToken).approve(address(v), type(uint256).max);
        }
        vm.deal(who, who.balance + DEPOSIT);
        vm.prank(who);
        v.commit{value: DEPOSIT}(id);
    }

    function _commit(address who, LimitOrder memory o, bytes32 salt) internal returns (bytes32) {
        return _commitOn(venue, who, o, salt);
    }

    function _commitEnd(SealedBatchAuction v, uint256 k) internal view returns (uint64 e) {
        (e,,,) = v.schedule(k);
    }

    function _revealEnd(SealedBatchAuction v, uint256 k) internal view returns (uint64 e) {
        (, e,,) = v.schedule(k);
    }

    function _toReveal(uint256 k) internal {
        vm.roll(_commitEnd(venue, k) + 1);
    }

    function _toSettle(uint256 k) internal {
        vm.roll(_revealEnd(venue, k) + 1);
    }

    /// Independent model of the volume function at price p.
    function _volume(LimitOrder[] memory os, uint256 p) internal view returns (uint256) {
        uint256 s;
        uint256 q;
        for (uint256 i = 0; i < os.length; i++) {
            if (os[i].sellToken == address(base)) {
                if (os[i].limitPrice <= p) s += os[i].sellAmount;
            } else if (os[i].limitPrice >= p) {
                q += os[i].sellAmount;
            }
        }
        uint256 d = q * S / p;
        return s < d ? s : d;
    }

    // ============ Commitments and schedule ============

    function test_commitmentBindsBatchVenueAndCommitter() public {
        LimitOrder memory o = _sell(1 ether, S);
        bytes32 h = venue.commitmentOf(0, _trader(1), o, bytes32("s"));
        assertTrue(h != venue.commitmentOf(1, _trader(1), o, bytes32("s")));
        assertTrue(h != venue.commitmentOf(0, _trader(2), o, bytes32("s")));
        SealedBatchAuction other = _venue(10, 1, 32);
        assertTrue(h != other.commitmentOf(0, _trader(1), o, bytes32("s")));
    }

    function test_batchesPipelineAndExpire() public {
        assertEq(venue.currentBatch(), 0);
        (uint64 ce, uint64 re, uint64 se, Phase p) = venue.schedule(0);
        assertEq(uint8(p), uint8(Phase.Commit));
        vm.roll(ce + 1);
        (,,, p) = venue.schedule(0);
        assertEq(uint8(p), uint8(Phase.Reveal));
        assertEq(venue.currentBatch(), 1); // batch 1 takes commitments while batch 0 is revealed
        vm.roll(re + 1);
        (,,, p) = venue.schedule(0);
        assertEq(uint8(p), uint8(Phase.Settling));
        vm.roll(se + 1);
        (,,, p) = venue.schedule(0);
        assertEq(uint8(p), uint8(Phase.Expired));
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.settle(0);
    }

    function test_scheduleRejectsOutOfRangeBatches() public {
        vm.expectRevert(SealedBatchAuction.BatchOutOfRange.selector);
        venue.schedule(uint256(1) << 64); // would alias batch 0 if truncated
    }

    function test_wrongDepositReverts() public {
        vm.deal(_trader(1), 1 ether);
        vm.prank(_trader(1));
        vm.expectRevert(SealedBatchAuction.BadDeposit.selector);
        venue.commit{value: DEPOSIT + 1}(bytes32("x"));
    }

    function test_batchFull() public {
        SealedBatchAuction small = _venue(10, 1, 1);
        vm.deal(address(this), 1 ether);
        small.commit{value: DEPOSIT}(bytes32("a"));
        vm.expectRevert(SealedBatchAuction.BatchFull.selector);
        small.commit{value: DEPOSIT}(bytes32("b"));
    }

    // ============ Reveal ============

    function test_revealByRelayer() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, S);
        bytes32 id = _commit(alice, o, bytes32("salt"));
        _toReveal(0);
        vm.prank(address(0xBEEF)); // anyone holding the opening can reveal
        venue.reveal(0, alice, o, bytes32("salt"));
        (,, SealedBatchAuction.Status st,,,) = venue.commitmentInfo(id);
        assertEq(uint8(st), uint8(SealedBatchAuction.Status.Revealed));
        assertEq(base.balanceOf(address(venue)), 1 ether);
    }

    function test_cannotRevealAnOrderInAnotherAccountsName() public {
        address victim = _trader(1);
        address attacker = _trader(2);
        LimitOrder memory o = _sell(5 ether, 1); // a terrible price, at the victim's expense
        base.mint(victim, 5 ether);
        vm.prank(victim);
        base.approve(address(venue), type(uint256).max);
        bytes32 id = venue.commitmentOf(0, victim, o, bytes32("x"));
        vm.deal(attacker, DEPOSIT);
        vm.prank(attacker);
        venue.commit{value: DEPOSIT}(id);
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.NotCommitter.selector);
        venue.reveal(0, victim, o, bytes32("x"));
        assertEq(base.balanceOf(victim), 5 ether);
    }

    function test_revealOutsideWindowReverts() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, S);
        _commit(alice, o, bytes32("s"));
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.reveal(0, alice, o, bytes32("s"));
        _toSettle(0);
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.reveal(0, alice, o, bytes32("s"));
    }

    function test_wrongOpeningReverts() public {
        address alice = _trader(1);
        _commit(alice, _sell(1 ether, S), bytes32("s"));
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.UnknownCommitment.selector);
        venue.reveal(0, alice, _sell(1 ether, S), bytes32("wrong"));
    }

    function test_feeOnTransferTokenRefused() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, S);
        _commit(alice, o, bytes32("s"));
        base.setFee(100);
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.EscrowShort.selector);
        venue.reveal(0, alice, o, bytes32("s"));
    }

    // ---- Regression for review finding 1 (F1): a late commitment cannot be opened into an earlier batch ----
    function test_lateCommitmentCannotEnterAnEarlierBatch() public {
        LimitOrder memory s = _sell(10 ether, S);
        LimitOrder memory b = _buy(20 ether, 2 * S);
        _commit(_trader(1), s, "s");
        _commit(_trader(2), b, "b");
        _toReveal(0);
        venue.reveal(0, _trader(1), s, "s");
        venue.reveal(0, _trader(2), b, "b");
        // Last block of batch 0's reveal window: the book is public and batch 1 is taking commitments.
        vm.roll(_revealEnd(venue, 0));
        LimitOrder memory late = _sell(1 ether, 1.99e18);
        bytes32 forBatch0 = venue.commitmentOf(0, _trader(9), late, "d");
        base.mint(_trader(9), 1 ether);
        vm.prank(_trader(9));
        base.approve(address(venue), type(uint256).max);
        vm.deal(_trader(9), DEPOSIT);
        vm.prank(_trader(9));
        venue.commit{value: DEPOSIT}(forBatch0); // recorded in batch 1, the batch that is current
        vm.expectRevert(SealedBatchAuction.WrongBatch.selector);
        venue.reveal(0, _trader(9), late, "d");
        _toSettle(0);
        venue.settle(0);
        (,, uint256 p) = venue.batches(0);
        assertEq(p, 1.5e18);
    }

    // ---- Regression for F3: an opening for another batch cannot be revealed, so it cannot be claimed twice ----
    function test_crossBatchOpeningCannotBeRevealed() public {
        LimitOrder memory h = _sell(100 ether, 1);
        bytes32 forBatch1 = venue.commitmentOf(1, _trader(1), h, "h");
        base.mint(_trader(1), 100 ether);
        vm.prank(_trader(1));
        base.approve(address(venue), type(uint256).max);
        vm.deal(_trader(1), DEPOSIT);
        vm.prank(_trader(1));
        venue.commit{value: DEPOSIT}(forBatch1); // made during batch 0
        vm.roll(_commitEnd(venue, 1) + 1); // batch 1's reveal window
        vm.expectRevert(SealedBatchAuction.WrongBatch.selector);
        venue.reveal(1, _trader(1), h, "h");
        assertEq(base.balanceOf(_trader(1)), 100 ether);
    }

    // ---- Regression for F4: revealed orders per batch never exceed the cap, and settle fits one transaction ----
    function test_settleAtCapFitsTheTransactionGasCap() public {
        SealedBatchAuction v = _venue(10, 1, 64);
        LimitOrder[] memory os = new LimitOrder[](64);
        for (uint256 i = 0; i < 64; i++) {
            os[i] = i % 2 == 0 ? _sell(1 ether + i, 0.8e18 + i * 1e15) : _buy(1 ether + i, 1.2e18 - i * 1e15);
            _commitOn(v, _trader(i), os[i], bytes32(i));
        }
        vm.roll(_commitEnd(v, 0) + 1);
        for (uint256 i = 0; i < 64; i++) {
            v.reveal(0, _trader(i), os[i], bytes32(i));
        }
        assertEq(v.revealedCount(0), 64);
        vm.roll(_revealEnd(v, 0) + 1);
        uint256 g = gasleft();
        (bool ok,) = address(v).call{gas: 16_777_216}(abi.encodeCall(v.settle, (0)));
        emit log_named_uint("settle gas, 64 orders", g - gasleft());
        assertTrue(ok, "settle at the cap must fit under the EIP-7825 per-transaction cap");
        (,, uint256 p) = v.batches(0);
        assertGt(p, 0);
    }

    // ---- Regression for F5: orders that cannot trade forfeit, so the cap is not free to fill ----
    function test_untradableOrdersForfeit() public {
        MockERC20 other = new MockERC20();
        LimitOrder memory junk = LimitOrder(address(other), address(quote), 1 ether, S);
        bytes32 id = _commit(_trader(1), junk, "j");
        _toReveal(0);
        venue.reveal(0, _trader(1), junk, "j"); // opens, but nothing is escrowed
        assertEq(other.balanceOf(address(venue)), 0);
        assertEq(venue.revealedCount(0), 0);
        _toSettle(0);
        venue.settle(0);
        uint256 before = _trader(1).balance;
        venue.claim(0, id);
        assertEq(_trader(1).balance - before, DEPOSIT / 2);
        assertEq(venue.sinkEth(), DEPOSIT / 2);
    }

    function test_belowMinimumSizeForfeits() public {
        SealedBatchAuction v = _venue(10, 1 ether, 32);
        LimitOrder memory small = _sell(0.5 ether, S);
        bytes32 id = _commitOn(v, _trader(1), small, "m");
        vm.roll(_commitEnd(v, 0) + 1);
        v.reveal(0, _trader(1), small, "m");
        (,, SealedBatchAuction.Status st,,,) = v.commitmentInfo(id);
        assertEq(uint8(st), uint8(SealedBatchAuction.Status.Invalid));
        assertEq(base.balanceOf(address(v)), 0);
    }

    // ============ Forfeit and expiry ============

    function test_unrevealedCommitmentForfeits() public {
        address alice = _trader(1);
        bytes32 id = _commit(alice, _sell(1 ether, S), bytes32("s"));
        _toSettle(0);
        uint256 before = alice.balance;
        venue.claim(0, id);
        assertEq(alice.balance - before, DEPOSIT / 2);
        venue.flushSink(address(0));
        assertEq(sink.balance, DEPOSIT / 2);
    }

    function test_expiredBatchRefundsEscrowInFull() public {
        LimitOrder memory s = _sell(10 ether, S);
        LimitOrder memory b = _buy(20 ether, 2 * S);
        bytes32 ia = _commit(_trader(1), s, "a");
        bytes32 ib = _commit(_trader(2), b, "b");
        _toReveal(0);
        venue.reveal(0, _trader(1), s, "a");
        venue.reveal(0, _trader(2), b, "b");
        _toSettle(0);
        vm.expectRevert(SealedBatchAuction.NotClaimable.selector);
        venue.claim(0, ia); // escrow waits for settlement while the batch can still settle
        (,, uint64 se,) = venue.schedule(0);
        vm.roll(se + 1); // nobody settled in time
        venue.claim(0, ia);
        venue.claim(0, ib);
        assertEq(base.balanceOf(_trader(1)), 10 ether);
        assertEq(quote.balanceOf(_trader(2)), 20 ether);
        assertEq(_trader(1).balance, DEPOSIT);
    }

    // ============ Settlement ============

    function test_settleTooEarlyAndTwiceReverts() public {
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.settle(0);
        _toSettle(0);
        venue.settle(0);
        vm.expectRevert(SealedBatchAuction.AlreadySettled.selector);
        venue.settle(0);
    }

    function test_noCrossMeansNoTrade() public {
        LimitOrder memory s = _sell(1 ether, 2 * S);
        LimitOrder memory b = _buy(1 ether, S);
        bytes32 ia = _commit(_trader(1), s, bytes32("a"));
        bytes32 ib = _commit(_trader(2), b, bytes32("b"));
        _toReveal(0);
        venue.reveal(0, _trader(1), s, bytes32("a"));
        venue.reveal(0, _trader(2), b, bytes32("b"));
        _toSettle(0);
        venue.settle(0);
        (, bool settled, uint256 price) = venue.batches(0);
        assertTrue(settled);
        assertEq(price, 0);
        venue.claim(0, ia);
        venue.claim(0, ib);
        assertEq(base.balanceOf(_trader(1)), 1 ether);
        assertEq(quote.balanceOf(_trader(2)), 1 ether);
    }

    function test_simpleCrossClearsAtMidpoint() public {
        LimitOrder memory s = _sell(10 ether, S); // at least 1.0
        LimitOrder memory b = _buy(20 ether, 2 * S); // at most 2.0, brings 20 quote
        bytes32 ia = _commit(_trader(1), s, bytes32("a"));
        bytes32 ib = _commit(_trader(2), b, bytes32("b"));
        _toReveal(0);
        venue.reveal(0, _trader(1), s, bytes32("a"));
        venue.reveal(0, _trader(2), b, bytes32("b"));
        _toSettle(0);
        venue.settle(0);
        (,, uint256 price) = venue.batches(0);
        assertEq(price, 1.5e18); // volume is 10 base at both limits; midpoint
        venue.claim(0, ia);
        venue.claim(0, ib);
        assertEq(quote.balanceOf(_trader(1)), 15 ether);
        assertEq(base.balanceOf(_trader(2)), 10 ether);
        assertEq(quote.balanceOf(_trader(2)), 5 ether);
    }

    // ---- Regression for F2: with a tie tolerance, a dust order no longer moves the price ----
    function test_dustDoesNotMoveThePriceWithinTolerance() public {
        LimitOrder memory s = _sell(10 ether, S);
        LimitOrder memory b = _buy(20 ether, 2 * S);
        LimitOrder memory dust = _sell(1, 1.99e18);
        _commit(_trader(1), s, "s");
        _commit(_trader(2), b, "b");
        _commit(_trader(3), dust, "d");
        _toReveal(0);
        venue.reveal(0, _trader(1), s, "s");
        venue.reveal(0, _trader(2), b, "b");
        venue.reveal(0, _trader(3), dust, "d");
        _toSettle(0);
        venue.settle(0);
        (,, uint256 p) = venue.batches(0);
        // Without tolerance the dust order would set the price to 1.99; the limits within 10 bps of the maximum
        // volume still span [1.0, 2.0], so the price stays close to the midpoint.
        assertGe(p, 1.49e18);
        assertLe(p, 1.51e18);
    }

    function test_withoutToleranceDustSetsThePrice() public {
        SealedBatchAuction v = _venue(0, 1, 32);
        LimitOrder memory s = _sell(10 ether, S);
        LimitOrder memory b = _buy(20 ether, 2 * S);
        LimitOrder memory dust = _sell(1, 1.99e18);
        _commitOn(v, _trader(1), s, "s");
        _commitOn(v, _trader(2), b, "b");
        _commitOn(v, _trader(3), dust, "d");
        vm.roll(_commitEnd(v, 0) + 1);
        v.reveal(0, _trader(1), s, "s");
        v.reveal(0, _trader(2), b, "b");
        v.reveal(0, _trader(3), dust, "d");
        vm.roll(_revealEnd(v, 0) + 1);
        v.settle(0);
        (,, uint256 p) = v.batches(0);
        assertEq(p, 1.99e18); // the fragility the tolerance exists to remove
    }

    function test_pricePriorityThenProRataAtTheMargin() public {
        LimitOrder memory s1 = _sell(6 ether, 0.5e18); // best limit: fills in full
        LimitOrder memory s2 = _sell(8 ether, 0.9e18); // marginal level
        LimitOrder memory s3 = _sell(8 ether, 0.9e18); // marginal level
        LimitOrder memory b = _buy(9 ether, 0.9e18); // 9 quote at most 0.9: 10 base
        bytes32 i1 = _commit(_trader(1), s1, "1");
        bytes32 i2 = _commit(_trader(2), s2, "2");
        bytes32 i3 = _commit(_trader(3), s3, "3");
        bytes32 ib = _commit(_trader(4), b, "4");
        _toReveal(0);
        venue.reveal(0, _trader(1), s1, "1");
        venue.reveal(0, _trader(2), s2, "2");
        venue.reveal(0, _trader(3), s3, "3");
        venue.reveal(0, _trader(4), b, "4");
        _toSettle(0);
        venue.settle(0);
        (,, uint256 price) = venue.batches(0);
        assertEq(price, 0.9e18);
        (,,,, uint256 sold1,) = venue.commitmentInfo(i1);
        (,,,, uint256 sold2,) = venue.commitmentInfo(i2);
        (,,,, uint256 sold3,) = venue.commitmentInfo(i3);
        assertEq(sold1, 6 ether);
        assertEq(sold2, 2 ether);
        assertEq(sold3, 2 ether);
        (,,,, uint256 soldB, uint256 boughtB) = venue.commitmentInfo(ib);
        assertEq(soldB, 9 ether);
        assertEq(boughtB, 10 ether);
    }

    // ============ Payments ============

    function test_committerThatRejectsEtherIsCreditedNotStuck() public {
        PickyReceiver r = new PickyReceiver();
        LimitOrder memory s = _sell(1 ether, S);
        base.mint(address(r), 1 ether);
        r.approve(base, address(venue));
        bytes32 id = venue.commitmentOf(0, address(r), s, "r");
        vm.deal(address(this), DEPOSIT);
        r.commit{value: DEPOSIT}(venue, id);
        _toReveal(0);
        venue.reveal(0, address(r), s, "r");
        _toSettle(0);
        venue.settle(0);
        venue.claim(0, id); // does not revert
        assertEq(base.balanceOf(address(r)), 1 ether); // the token part was paid
        assertEq(venue.owed(address(0), address(r)), DEPOSIT); // the ether part is held for it
        r.setAccept(true);
        r.withdraw(venue, address(0));
        assertEq(address(r).balance, DEPOSIT);
    }

    function test_blockedTokenRecipientIsCredited() public {
        LimitOrder memory s = _sell(1 ether, S);
        bytes32 id = _commit(_trader(1), s, "s");
        _toReveal(0);
        venue.reveal(0, _trader(1), s, "s");
        _toSettle(0);
        venue.settle(0);
        base.setBlocked(_trader(1), true);
        venue.claim(0, id);
        assertEq(venue.owed(address(base), _trader(1)), 1 ether);
        assertEq(_trader(1).balance, DEPOSIT); // the deposit still arrived
    }

    // ============ Properties ============

    /// Random batches: every token and every wei of deposit ends with a trader or the sink; the venue keeps
    /// nothing; every fill is at the clearing price and within its limit; the price's volume is within the tie
    /// tolerance of the best volume at any order limit; rounding dust is small.
    function testFuzz_settlementProperties(uint8 nOrders, uint256 seed, bool exact) public {
        SealedBatchAuction v = _venue(exact ? 0 : 10, 1, 32);
        uint256 n = bound(nOrders, 2, 12);
        LimitOrder[] memory os = new LimitOrder[](n);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(r, 1e9, 1e24);
            uint256 price = bound(r >> 96, 0.25e18, 4e18);
            os[i] = (r >> 200) % 2 == 0 ? _sell(amount, price) : _buy(amount, price);
            ids[i] = _commitOn(v, _trader(i), os[i], bytes32(i));
        }
        vm.roll(_commitEnd(v, 0) + 1);
        for (uint256 i = 0; i < n; i++) {
            v.reveal(0, _trader(i), os[i], bytes32(i));
        }
        vm.roll(_revealEnd(v, 0) + 1);
        v.settle(0);
        (,, uint256 p) = v.batches(0);

        if (p > 0) {
            uint256 best;
            for (uint256 i = 0; i < n; i++) {
                uint256 vol = _volume(os, os[i].limitPrice);
                if (vol > best) best = vol;
            }
            uint256 tol = exact ? 0 : 10;
            assertGe(_volume(os, p), best - best * tol / 10_000, "clearing volume below the tolerance band");
            assertLe(v.sinkTokens(address(base)), n + S / p + 1, "base dust too large");
            assertLe(v.sinkTokens(address(quote)), n + p / S + 1, "quote dust too large");
        }

        for (uint256 i = 0; i < n; i++) {
            (,,,, uint256 sold, uint256 bought) = v.commitmentInfo(ids[i]);
            assertLe(sold, os[i].sellAmount);
            if (sold == 0) continue;
            if (os[i].sellToken == address(base)) {
                assertLe(os[i].limitPrice, p, "seller filled below its limit");
                assertEq(bought, sold * p / S, "seller not paid the clearing price");
            } else {
                assertGe(os[i].limitPrice, p, "buyer filled above its limit");
                assertEq(bought, sold * S / p, "buyer not paid the clearing price");
            }
        }

        for (uint256 i = 0; i < n; i++) {
            v.claim(0, ids[i]);
        }
        v.flushSink(address(0));
        v.flushSink(address(base));
        v.flushSink(address(quote));
        assertEq(base.balanceOf(address(v)), 0, "venue kept base");
        assertEq(quote.balanceOf(address(v)), 0, "venue kept quote");
        assertEq(address(v).balance, 0, "venue kept ether");
        uint256 baseHeld = base.balanceOf(sink);
        uint256 quoteHeld = quote.balanceOf(sink);
        for (uint256 i = 0; i < n; i++) {
            baseHeld += base.balanceOf(_trader(i));
            quoteHeld += quote.balanceOf(_trader(i));
        }
        assertEq(baseHeld, base.totalSupply());
        assertEq(quoteHeld, quote.totalSupply());
    }

    /// Guards against a vacuous fuzz test: the same generator must produce batches that actually trade.
    function test_fuzzGeneratorProducesTrades() public {
        uint256 cleared;
        for (uint256 seed = 0; seed < 40; seed++) {
            SealedBatchAuction v = _venue(10, 1, 32);
            uint256 n = 2 + seed % 11;
            LimitOrder[] memory os = new LimitOrder[](n);
            for (uint256 i = 0; i < n; i++) {
                uint256 r = uint256(keccak256(abi.encode(seed, i)));
                os[i] = (r >> 200) % 2 == 0
                    ? _sell(bound(r, 1e9, 1e24), bound(r >> 96, 0.25e18, 4e18))
                    : _buy(bound(r, 1e9, 1e24), bound(r >> 96, 0.25e18, 4e18));
                _commitOn(v, _trader(i), os[i], bytes32(i));
            }
            vm.roll(_commitEnd(v, 0) + 1);
            for (uint256 i = 0; i < n; i++) {
                v.reveal(0, _trader(i), os[i], bytes32(i));
            }
            vm.roll(_revealEnd(v, 0) + 1);
            v.settle(0);
            (,, uint256 p) = v.batches(0);
            if (p > 0) cleared++;
        }
        emit log_named_uint("batches out of 40 that traded", cleared);
        assertGe(cleared, 15);
    }

    function test_supportsInterface() public view {
        assertTrue(venue.supportsInterface(type(IERCSealedBatchAuction).interfaceId));
        assertTrue(venue.supportsInterface(0xf14fcbc8)); // ERC-5732 IERC_COMMIT_CORE
        assertTrue(venue.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(venue.supportsInterface(0xdeadbeef));
    }
}

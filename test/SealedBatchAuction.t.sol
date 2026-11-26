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

    function setFee(uint256 bps) external {
        feeBps = bps;
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
        require(balanceOf[from] >= amount, "balance");
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

contract SealedBatchAuctionTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant DEPOSIT = 0.01 ether;
    uint64 constant C = 5;
    uint64 constant R = 3;

    SealedBatchAuction venue;
    MockERC20 base;
    MockERC20 quote;
    address sink = address(0x5111C);

    function setUp() public {
        MockERC20 a = new MockERC20();
        MockERC20 b = new MockERC20();
        (base, quote) = address(a) < address(b) ? (a, b) : (b, a);
        venue = new SealedBatchAuction(address(a), address(b), C, R, DEPOSIT, 5000, 32, sink);
        assertEq(venue.base(), address(base));
        assertEq(venue.quote(), address(quote));
    }

    // ============ Helpers ============

    function _trader(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// A seller of base: sells `amount` base, wants at least `limit` quote per base.
    function _sell(uint256 amount, uint256 limit) internal view returns (LimitOrder memory) {
        return LimitOrder(address(base), address(quote), amount, limit);
    }

    /// A buyer of base: sells `amount` quote and pays at most `maxPrice` quote per base, which is a limit of
    /// at least 1e36 / maxPrice base per quote.
    function _buy(uint256 amount, uint256 maxPrice) internal view returns (LimitOrder memory) {
        return LimitOrder(address(quote), address(base), amount, ONE * ONE / maxPrice);
    }

    function _commit(address who, LimitOrder memory o, bytes32 salt) internal returns (bytes32 id) {
        uint256 batchId = venue.currentBatch();
        id = venue.commitmentOf(batchId, who, o, salt);
        MockERC20(o.sellToken).mint(who, o.sellAmount);
        vm.deal(who, who.balance + DEPOSIT);
        vm.startPrank(who);
        MockERC20(o.sellToken).approve(address(venue), o.sellAmount);
        venue.commit{value: DEPOSIT}(id);
        vm.stopPrank();
    }

    function _toReveal(uint256 batchId) internal {
        (uint64 commitEnd,,) = venue.schedule(batchId);
        vm.roll(commitEnd + 1);
    }

    function _toSettle(uint256 batchId) internal {
        (, uint64 revealEnd,) = venue.schedule(batchId);
        vm.roll(revealEnd + 1);
    }

    /// Independent model of the volume function: min(base supply, base demand) at price p.
    function _volume(LimitOrder[] memory os, uint256 p) internal view returns (uint256) {
        uint256 s;
        uint256 q;
        for (uint256 i = 0; i < os.length; i++) {
            if (os[i].sellToken == address(base)) {
                if (os[i].limitPrice <= p) s += os[i].sellAmount;
            } else if (p * os[i].limitPrice <= ONE * ONE) {
                q += os[i].sellAmount;
            }
        }
        uint256 d = q * ONE / p;
        return s < d ? s : d;
    }

    // ============ Commitments and schedule ============

    function test_commitmentBindsBatchVenueAndCommitter() public {
        LimitOrder memory o = _sell(1 ether, ONE);
        bytes32 h = venue.commitmentOf(0, _trader(1), o, bytes32("s"));
        assertTrue(h != venue.commitmentOf(1, _trader(1), o, bytes32("s")));
        assertTrue(h != venue.commitmentOf(0, _trader(2), o, bytes32("s")));
        SealedBatchAuction other =
            new SealedBatchAuction(address(base), address(quote), C, R, DEPOSIT, 5000, 32, sink);
        assertTrue(h != other.commitmentOf(0, _trader(1), o, bytes32("s")));
    }

    function test_batchesPipeline() public {
        assertEq(venue.currentBatch(), 0);
        (uint64 commitEnd0, uint64 revealEnd0, Phase p0) = venue.schedule(0);
        assertEq(uint8(p0), uint8(Phase.Commit));
        vm.roll(commitEnd0 + 1);
        (,, p0) = venue.schedule(0);
        assertEq(uint8(p0), uint8(Phase.Reveal));
        assertEq(venue.currentBatch(), 1); // batch 1 takes commitments while batch 0 reveals
        vm.roll(revealEnd0 + 1);
        (,, p0) = venue.schedule(0);
        assertEq(uint8(p0), uint8(Phase.Settling));
        venue.settle(0);
        (,, p0) = venue.schedule(0);
        assertEq(uint8(p0), uint8(Phase.Settled));
    }

    function test_wrongDepositReverts() public {
        vm.deal(_trader(1), 1 ether);
        vm.prank(_trader(1));
        vm.expectRevert(SealedBatchAuction.BadDeposit.selector);
        venue.commit{value: DEPOSIT + 1}(bytes32("x"));
    }

    function test_batchFull() public {
        SealedBatchAuction small = new SealedBatchAuction(address(base), address(quote), C, R, DEPOSIT, 5000, 1, sink);
        vm.deal(address(this), 1 ether);
        small.commit{value: DEPOSIT}(bytes32("a"));
        vm.expectRevert(SealedBatchAuction.BatchFull.selector);
        small.commit{value: DEPOSIT}(bytes32("b"));
    }

    // ============ Reveal ============

    function test_revealByRelayer() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, ONE);
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
        vm.prank(attacker);
        vm.expectRevert(SealedBatchAuction.NotCommitter.selector);
        venue.reveal(0, victim, o, bytes32("x"));
        assertEq(base.balanceOf(victim), 5 ether);
    }

    function test_revealOutsideWindowReverts() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, ONE);
        _commit(alice, o, bytes32("s"));
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.reveal(0, alice, o, bytes32("s")); // still the commit window
        _toSettle(0);
        vm.expectRevert(SealedBatchAuction.WrongPhase.selector);
        venue.reveal(0, alice, o, bytes32("s")); // too late
    }

    function test_wrongOpeningReverts() public {
        address alice = _trader(1);
        _commit(alice, _sell(1 ether, ONE), bytes32("s"));
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.UnknownCommitment.selector);
        venue.reveal(0, alice, _sell(1 ether, ONE), bytes32("wrong"));
    }

    function test_feeOnTransferTokenRefused() public {
        address alice = _trader(1);
        LimitOrder memory o = _sell(1 ether, ONE);
        _commit(alice, o, bytes32("s"));
        base.setFee(100);
        _toReveal(0);
        vm.expectRevert(SealedBatchAuction.EscrowShort.selector);
        venue.reveal(0, alice, o, bytes32("s"));
    }

    function test_unsupportedPairIsRefundedNotForfeited() public {
        address alice = _trader(1);
        MockERC20 other = new MockERC20();
        LimitOrder memory o = LimitOrder(address(other), address(quote), 1 ether, ONE);
        bytes32 id = _commit(alice, o, bytes32("s"));
        _toReveal(0);
        venue.reveal(0, alice, o, bytes32("s"));
        _toSettle(0);
        venue.settle(0);
        uint256 before = alice.balance;
        venue.claim(0, id);
        assertEq(alice.balance - before, DEPOSIT);
        assertEq(other.balanceOf(alice), 1 ether); // never escrowed
    }

    // ============ Forfeit ============

    function test_unrevealedCommitmentForfeits() public {
        address alice = _trader(1);
        bytes32 id = _commit(alice, _sell(1 ether, ONE), bytes32("s"));
        _toSettle(0);
        uint256 before = alice.balance;
        venue.claim(0, id);
        assertEq(alice.balance - before, DEPOSIT / 2);
        assertEq(venue.sinkEth(), DEPOSIT / 2);
        venue.flushSink();
        assertEq(sink.balance, DEPOSIT / 2);
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
        address alice = _trader(1);
        address bob = _trader(2);
        LimitOrder memory s = _sell(1 ether, 2 * ONE); // wants 2 quote per base
        LimitOrder memory b = _buy(1 ether, ONE); // pays at most 1 quote per base
        bytes32 ia = _commit(alice, s, bytes32("a"));
        bytes32 ib = _commit(bob, b, bytes32("b"));
        _toReveal(0);
        venue.reveal(0, alice, s, bytes32("a"));
        venue.reveal(0, bob, b, bytes32("b"));
        _toSettle(0);
        venue.settle(0);
        (, bool settled, uint256 price) = venue.batches(0);
        assertTrue(settled);
        assertEq(price, 0);
        venue.claim(0, ia);
        venue.claim(0, ib);
        assertEq(base.balanceOf(alice), 1 ether);
        assertEq(quote.balanceOf(bob), 1 ether);
    }

    function test_simpleCrossClearsAtMidpoint() public {
        address alice = _trader(1);
        address bob = _trader(2);
        LimitOrder memory s = _sell(10 ether, ONE); // at least 1.0
        LimitOrder memory b = _buy(20 ether, 2 * ONE); // at most 2.0, brings 20 quote
        bytes32 ia = _commit(alice, s, bytes32("a"));
        bytes32 ib = _commit(bob, b, bytes32("b"));
        _toReveal(0);
        venue.reveal(0, alice, s, bytes32("a"));
        venue.reveal(0, bob, b, bytes32("b"));
        _toSettle(0);
        venue.settle(0);
        (,, uint256 price) = venue.batches(0);
        // Volume is 10 base at every price in [1.0, 2.0]; the midpoint is 1.5.
        assertEq(price, 1.5e18);
        venue.claim(0, ia);
        venue.claim(0, ib);
        assertEq(quote.balanceOf(alice), 15 ether); // 10 base at 1.5
        assertEq(base.balanceOf(bob), 10 ether);
        assertEq(quote.balanceOf(bob), 5 ether); // unspent quote returned
    }

    function test_pricePriorityThenProRataAtTheMargin() public {
        // Three sellers, one buyer who only takes 10 base at the price.
        LimitOrder memory s1 = _sell(6 ether, 0.5e18); // best limit: fills in full
        LimitOrder memory s2 = _sell(8 ether, 0.9e18); // marginal level, shares the rest
        LimitOrder memory s3 = _sell(8 ether, 0.9e18); // marginal level, shares the rest
        LimitOrder memory b = _buy(9 ether, 0.9e18); // 9 quote at most 0.9 per base: 10 base
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

    // ============ Properties ============

    struct Fuzz {
        uint8 n;
        uint256 seed;
    }

    /// Random batches: every token and every wei of deposit ends with a trader or the sink; the venue keeps
    /// nothing; every fill is at the clearing price and within its limit; the price maximizes volume.
    function testFuzz_settlementProperties(uint8 nOrders, uint256 seed) public {
        uint256 n = bound(nOrders, 2, 12);
        LimitOrder[] memory os = new LimitOrder[](n);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(r, 1e9, 1e24);
            uint256 price = bound(r >> 96, 0.25e18, 4e18);
            os[i] = (r >> 200) % 2 == 0 ? _sell(amount, price) : _buy(amount, price);
            ids[i] = _commit(_trader(i), os[i], bytes32(i));
        }
        _toReveal(0);
        for (uint256 i = 0; i < n; i++) {
            venue.reveal(0, _trader(i), os[i], bytes32(i));
        }
        _toSettle(0);
        venue.settle(0);
        (,, uint256 p) = venue.batches(0);

        if (p > 0) {
            // Volume maximality against the independent model, at every limit and at nearby prices.
            uint256 best = _volume(os, p);
            for (uint256 i = 0; i < n; i++) {
                uint256 k = os[i].sellToken == address(base) ? os[i].limitPrice : ONE * ONE / os[i].limitPrice;
                assertLe(_volume(os, k), best, "a limit price has more volume than the clearing price");
            }
            assertLe(_volume(os, p + 1), best);
            assertLe(_volume(os, p - 1), best);
        }

        for (uint256 i = 0; i < n; i++) {
            (,,,, uint256 sold, uint256 bought) = venue.commitmentInfo(ids[i]);
            assertLe(sold, os[i].sellAmount);
            if (sold == 0) continue;
            if (os[i].sellToken == address(base)) {
                assertLe(os[i].limitPrice, p, "seller filled below its limit");
                assertEq(bought, sold * p / ONE, "seller not paid the clearing price");
            } else {
                assertLe(p * os[i].limitPrice, ONE * ONE, "buyer filled above its limit");
                assertEq(bought, sold * ONE / p, "buyer not paid the clearing price");
            }
        }

        // Rounding dust is small: at most one unit per order, plus what one unit of the other token is worth.
        if (p > 0) {
            assertLe(venue.sinkTokens(address(base)), n + ONE / p + 1, "base dust too large");
            assertLe(venue.sinkTokens(address(quote)), n + p / ONE + 1, "quote dust too large");
        }

        for (uint256 i = 0; i < n; i++) {
            venue.claim(0, ids[i]);
        }
        venue.flushSink();
        assertEq(base.balanceOf(address(venue)), 0, "venue kept base");
        assertEq(quote.balanceOf(address(venue)), 0, "venue kept quote");
        assertEq(address(venue).balance, 0, "venue kept ether");
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
            uint256 snap = vm.snapshotState();
            uint256 n = 2 + seed % 11;
            for (uint256 i = 0; i < n; i++) {
                uint256 r = uint256(keccak256(abi.encode(seed, i)));
                uint256 amount = bound(r, 1e9, 1e24);
                uint256 price = bound(r >> 96, 0.25e18, 4e18);
                LimitOrder memory o = (r >> 200) % 2 == 0 ? _sell(amount, price) : _buy(amount, price);
                _commit(_trader(i), o, bytes32(i));
                _toReveal(0);
                venue.reveal(0, _trader(i), o, bytes32(i));
                vm.roll(venue.genesis()); // back into the commit window for the next order
            }
            _toSettle(0);
            venue.settle(0);
            (,, uint256 p) = venue.batches(0);
            if (p > 0) cleared++;
            vm.revertToState(snap);
        }
        emit log_named_uint("batches out of 40 that traded", cleared);
        assertGe(cleared, 15);
    }

    /// Settlement gas at the commitment cap (32 orders), for the Security Considerations section.
    function test_gasAtCap() public {
        LimitOrder[] memory os = new LimitOrder[](32);
        for (uint256 i = 0; i < 32; i++) {
            os[i] = i % 2 == 0 ? _sell(1 ether + i, 0.8e18 + i * 1e16) : _buy(1 ether + i, 1.2e18 - i * 1e16);
            _commit(_trader(i), os[i], bytes32(i));
        }
        _toReveal(0);
        for (uint256 i = 0; i < 32; i++) {
            venue.reveal(0, _trader(i), os[i], bytes32(i));
        }
        _toSettle(0);
        uint256 g = gasleft();
        venue.settle(0);
        emit log_named_uint("settle gas, 32 orders", g - gasleft());
        (,, uint256 p) = venue.batches(0);
        assertGt(p, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(venue.supportsInterface(type(IERCSealedBatchAuction).interfaceId));
        assertTrue(venue.supportsInterface(0xf14fcbc8)); // ERC-5732 IERC_COMMIT_CORE
        assertTrue(venue.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(venue.supportsInterface(0xdeadbeef));
    }
}
